local Activity = require("codecompanion.interactions.chat.ui.activity")
local utils = require("codecompanion.utils")

local api = vim.api

local M = {}

-- Marks a field the user left blank
local SKIP = {}

---@param property table
---@return { label: string, value: any }[]
local function enum_options(property)
  local options = {}

  if type(property.enum) == "table" then
    for _, value in ipairs(property.enum) do
      table.insert(options, { label = tostring(value), value = value })
    end
  elseif type(property.oneOf) == "table" then
    for _, option in ipairs(property.oneOf) do
      if option.const ~= nil then
        table.insert(options, { label = option.title or tostring(option.const), value = option.const })
      end
    end
  end

  return options
end

---@param property table
---@param name string
---@return string
local function prompt_for(property, name)
  local title = property.title or name
  if type(property.description) == "string" and property.description ~= "" then
    return ("%s (%s): "):format(title, property.description)
  end
  return ("%s: "):format(title)
end

---@param input string
---@param pattern string
---@return boolean
local function matches_pattern(input, pattern)
  local ok, regex = pcall(vim.regex, pattern)
  if not ok then
    return true
  end
  return regex:match_str(input) ~= nil
end

---@param property table
---@param name string
---@param callback fun(value: any)
---@return nil
local function ask_text(property, name, callback)
  local default = property.default
  vim.ui.input(
    { prompt = prompt_for(property, name), default = type(default) == "string" and default or nil },
    function(input)
      if input == nil then
        return callback(SKIP)
      end

      input = vim.trim(input)
      if input == "" then
        return callback(SKIP)
      end

      if type(property.pattern) == "string" and not matches_pattern(input, property.pattern) then
        utils.notify(("The answer must match %s"):format(property.pattern), vim.log.levels.WARN)
        return ask_text(property, name, callback)
      end

      callback(input)
    end
  )
end

---@param property table
---@param name string
---@param callback fun(value: any)
---@return nil
local function ask_number(property, name, callback)
  ask_text(property, name, function(value)
    if value == SKIP then
      return callback(SKIP)
    end

    local number = tonumber(value)
    if not number then
      utils.notify("Please enter a number", vim.log.levels.WARN)
      return ask_number(property, name, callback)
    end

    if property.type == "integer" then
      number = math.floor(number)
    end
    callback(number)
  end)
end

---@param options { label: string, value: any }[]
---@param prompt string
---@param callback fun(value: any)
---@return nil
local function ask_select(options, prompt, callback)
  vim.ui.select(options, {
    prompt = prompt,
    format_item = function(option)
      return option.label
    end,
  }, function(option)
    if not option then
      return callback(SKIP)
    end
    callback(option.value)
  end)
end

---@param property table
---@param name string
---@param callback fun(value: any)
---@return nil
local function ask_boolean(property, name, callback)
  ask_select({
    { label = "Yes", value = true },
    { label = "No", value = false },
  }, prompt_for(property, name), callback)
end

---@param property table
---@param name string
---@param callback fun(value: any)
---@return nil
local function ask_array(property, name, callback)
  local options = enum_options(property.items or {})

  if #options == 0 then
    return ask_text(property, name, function(value)
      if value == SKIP then
        return callback(SKIP)
      end
      local values = {}
      for _, item in ipairs(vim.split(value, ",", { plain = true })) do
        item = vim.trim(item)
        if item ~= "" then
          table.insert(values, item)
        end
      end
      callback(values)
    end)
  end

  local selected = {}
  for _, value in ipairs(type(property.default) == "table" and property.default or {}) do
    selected[value] = true
  end

  local function choose()
    local entries = {}
    for _, option in ipairs(options) do
      table.insert(entries, {
        label = (selected[option.value] and "[x] " or "[ ] ") .. option.label,
        option = option,
      })
    end
    table.insert(entries, { label = "Done", done = true })

    vim.ui.select(entries, {
      prompt = prompt_for(property, name),
      format_item = function(entry)
        return entry.label
      end,
    }, function(entry)
      if not entry then
        return callback(SKIP)
      end

      if entry.done then
        local values = {}
        for _, option in ipairs(options) do
          if selected[option.value] then
            table.insert(values, option.value)
          end
        end
        return callback(values)
      end

      selected[entry.option.value] = not selected[entry.option.value] or nil
      choose()
    end)
  end

  choose()
end

---@param name string
---@param property table
---@param callback fun(value: any)
---@return nil
local function ask_field(name, property, callback)
  local kind = property.type

  if kind == "boolean" then
    return ask_boolean(property, name, callback)
  end
  if kind == "array" then
    return ask_array(property, name, callback)
  end
  if kind == "number" or kind == "integer" then
    return ask_number(property, name, callback)
  end
  if kind == "string" then
    local options = enum_options(property)
    if #options > 0 then
      return ask_select(options, prompt_for(property, name), callback)
    end
    return ask_text(property, name, callback)
  end

  utils.notify(("This question uses a field CodeCompanion cannot show: %s"):format(tostring(kind)), vim.log.levels.WARN)
  callback(SKIP)
end

---@param message string
---@return string
local function card_title(message)
  local first = vim.split(message, "\n", { plain = true })[1] or message
  if #first > 80 then
    first = first:sub(1, 77) .. "..."
  end
  return "Agent question: " .. first
end

---@param chat CodeCompanion.Chat|nil
---@param card_id string
---@param output string[]
---@param status string
---@return nil
local function update_card(chat, card_id, output, status)
  if not chat or not api.nvim_buf_is_valid(chat.bufnr) then
    return
  end
  Activity.upsert(chat, {
    id = card_id,
    status = status,
    output = output,
  })
end

---Ask the user to fill in an agent's form, then hand the response back
---@param chat CodeCompanion.Chat|nil
---@param opts { id: number, params: table, respond: fun(response: table) }
---@return nil
function M.request(chat, opts)
  local params = opts.params or {}
  local schema = params.requestedSchema or {}
  local properties = schema.properties or {}
  local required = {}
  for _, name in ipairs(schema.required or {}) do
    required[name] = true
  end

  local names = vim.tbl_keys(properties)
  table.sort(names)

  local card_id = "elicitation:" .. opts.id
  local message = type(params.message) == "string" and params.message or "The agent needs your input"
  local output = vim.split(message, "\n", { plain = true })

  if chat and api.nvim_buf_is_valid(chat.bufnr) then
    Activity.upsert(chat, {
      id = card_id,
      title = card_title(message),
      kind = "elicitation",
      status = "running",
      output = output,
    })
  end

  local content = {}
  local index = 1

  local function finish(response)
    if response.action == "accept" then
      local answers = {}
      for _, name in ipairs(names) do
        if content[name] ~= nil then
          table.insert(answers, ("%s: %s"):format(name, tostring(content[name])))
        end
      end
      if #answers > 0 then
        table.insert(output, "")
        vim.list_extend(output, answers)
      end
    end
    update_card(chat, card_id, output, response.action == "accept" and "success" or "cancelled")
    opts.respond(response)
  end

  local function ask_next()
    local name = names[index]
    if not name then
      local answer = next(content) and content or nil
      return finish({ action = "accept", content = answer })
    end

    ask_field(name, properties[name], function(value)
      if value == SKIP then
        if required[name] then
          utils.notify(("%s needs an answer before the agent can continue"):format(name), vim.log.levels.WARN)
          return finish({ action = "cancel" })
        end
        index = index + 1
        return ask_next()
      end

      content[name] = value
      index = index + 1
      ask_next()
    end)
  end

  ask_next()
end

return M
