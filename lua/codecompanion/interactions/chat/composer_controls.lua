local adapter_utils = require("codecompanion.adapters.utils")
local approvals = require("codecompanion.interactions.chat.tools.approvals")
local config = require("codecompanion.config")
local utils = require("codecompanion.utils")

local M = {}
local namespace = vim.api.nvim_create_namespace("CodeCompanion-ComposerControls")

local approval_labels = {
  ask = "Default / Ask",
  auto = "Auto-approve safe actions",
  yolo = "Allow all",
}

---@param chat CodeCompanion.Chat
---@return string
local function model_label(chat)
  if chat.adapter.type == "http" then
    return adapter_utils.model(chat.adapter) or chat.adapter.formatted_name or chat.adapter.name
  end

  if chat.acp_connection then
    local models = chat.acp_connection:get_models()
    if models and models.currentModelId then
      return models.currentModelId
    end
  end
  return chat.adapter.formatted_name or chat.adapter.name
end

---@param chat CodeCompanion.Chat
---@return string[]
local function config_option_labels(chat)
  if chat.adapter.type ~= "acp" or not chat.acp_connection then
    return {}
  end

  local labels = {}
  for _, option in ipairs(chat.acp_connection:get_config_options()) do
    if option.type == "select" and option.currentValue then
      table.insert(labels, string.format("%s: %s", option.name, option.currentValue))
    end
  end
  return labels
end

---The effort/reasoning settings the active HTTP adapter advertises
---@param chat CodeCompanion.Chat
---@return { key: string, name: string, value?: string, choices: string[], order: number }[]
function M.effort_options(chat)
  if chat.adapter.type ~= "http" then
    return {}
  end

  local options = {}
  for key, schema in pairs(chat.adapter.schema or {}) do
    if type(key) == "string" and type(schema) == "table" and schema.choices then
      local lowered = key:lower()
      if lowered:find("effort", 1, true) or lowered:find("reasoning", 1, true) then
        local choices = schema.choices
        if type(choices) == "function" then
          local ok, resolved = pcall(choices, chat.adapter)
          choices = ok and resolved or nil
        end
        if vim.islist(choices) and #choices > 0 then
          local value = chat.settings and chat.settings[key]
          if value == nil then
            value = schema.default
            if type(value) == "function" then
              local ok, resolved = pcall(value, chat.adapter)
              value = ok and resolved or nil
            end
          end
          table.insert(options, {
            key = key,
            name = lowered:find("effort", 1, true) and "Effort" or "Reasoning",
            value = value,
            choices = choices,
            order = schema.order or 0,
          })
        end
      end
    end
  end

  table.sort(options, function(a, b)
    return a.order < b.order
  end)
  return options
end

---The context tags currently attached to the composer draft
---@param chat CodeCompanion.Chat
---@return { token: string, label: string }[]
function M.attached_context(chat)
  local composer = chat.composer
  if not composer or not vim.api.nvim_buf_is_valid(composer.bufnr) then
    return {}
  end

  local prefix = require("codecompanion.triggers").mappings.editor_context
  local pattern = vim.pesc(prefix) .. "{([^}]*)}"
  local seen, items = {}, {}
  for _, line in ipairs(vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false)) do
    for body in line:gmatch(pattern) do
      if body:match("^buffers?") then
        local token = prefix .. "{" .. body .. "}"
        if not seen[token] then
          seen[token] = true
          local label = body == "buffers" and "all open buffers"
            or ("buffer: " .. (body:match("^buffer:(.*)$") or "current"))
          table.insert(items, { token = token, label = label })
        end
      end
    end
  end
  return items
end

---@param chat CodeCompanion.Chat
---@param token string
---@return boolean
function M.has_context(chat, token)
  for _, item in ipairs(M.attached_context(chat)) do
    if item.token == token then
      return true
    end
  end
  return false
end

---@param chat CodeCompanion.Chat
---@return boolean
local function is_available(chat)
  return config.interactions.chat.opts.composer_controls
    and chat.ui ~= nil
    and chat.ui.winnr ~= nil
    and vim.api.nvim_win_is_valid(chat.ui.winnr)
    and vim.api.nvim_win_get_tabpage(chat.ui.winnr) == vim.api.nvim_get_current_tabpage()
    and chat.ui:is_visible()
end

---@param chat CodeCompanion.Chat
---@return nil
local function render_controls(chat)
  local composer = chat.composer
  if not composer or not vim.api.nvim_buf_is_valid(composer.bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(composer.bufnr, namespace, 0, -1)
  local controls = {
    { string.format(" Model: %s  ▾ ga", model_label(chat)), "Comment" },
  }
  for _, option in ipairs(M.effort_options(chat)) do
    table.insert(controls, {
      string.format("  %s: %s  ▾ gO", option.name, tostring(option.value or "")),
      "Comment",
    })
  end
  for _, label in ipairs(config_option_labels(chat)) do
    table.insert(controls, { string.format("  %s  ▾ gO", label), "Comment" })
  end

  local attached = M.attached_context(chat)
  local above = {
    { { " ＋ Attach context  g+", "Special" } },
  }
  if #attached > 0 then
    local chips = { { " Context: ", "Comment" } }
    for _, item in ipairs(attached) do
      table.insert(chips, { "[" .. item.label .. "] ", "Special" })
    end
    table.insert(chips, { " g+ to remove", "Comment" })
    table.insert(above, chips)
  end
  vim.api.nvim_buf_set_extmark(composer.bufnr, namespace, 0, 0, {
    virt_lines = above,
    virt_lines_above = true,
    priority = 110,
  })

  local row = math.max(0, vim.api.nvim_buf_line_count(composer.bufnr) - 1)
  vim.api.nvim_buf_set_extmark(composer.bufnr, namespace, row, 0, {
    virt_lines = {
      controls,
      {
        { " Permissions: ", "Comment" },
        { approval_labels[approvals:get_mode(chat.bufnr)] or "Default / Ask", "Special" },
        { "  ▾ gty", "Comment" },
        { "  Changed files  gF", "Comment" },
      },
    },
    priority = 110,
  })
end

---@param chat CodeCompanion.Chat
---@return nil
local function update_window(chat)
  local composer = chat.composer
  if not composer or not vim.api.nvim_win_is_valid(composer.winnr) then
    return
  end
  if not is_available(chat) then
    M.close(chat)
    return
  end

  local ok = pcall(vim.api.nvim_win_set_config, composer.winnr, {
    relative = "win",
    win = chat.ui.winnr,
    anchor = "SW",
    row = vim.api.nvim_win_get_height(chat.ui.winnr) - 1,
    col = 0,
    width = vim.api.nvim_win_get_width(chat.ui.winnr),
    height = 4,
  })
  if not ok then
    M.close(chat)
  end
end

---@param chat CodeCompanion.Chat
---@return nil
function M.close(chat)
  local composer = chat.composer
  chat.composer = nil
  if composer and vim.api.nvim_buf_is_valid(composer.bufnr) then
    chat._composer_draft = vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false)
  end
  if composer and vim.api.nvim_win_is_valid(composer.winnr) then
    pcall(vim.api.nvim_win_close, composer.winnr, true)
  end
end

---@param chat CodeCompanion.Chat
---@return nil
function M.submit(chat)
  local composer = chat.composer
  if not composer or chat.current_request then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false)
  if vim.trim(table.concat(lines, "\n")) == "" then
    return
  end

  vim.api.nvim_buf_set_lines(chat.bufnr, chat.header_line, -1, false, lines)
  local result = chat:submit()
  if chat.current_request then
    vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, { "" })
    chat._composer_draft = nil
  end
  return result
end

---@param chat CodeCompanion.Chat
---@return nil
function M.select_effort(chat)
  local options = M.effort_options(chat)
  if #options == 0 then
    return utils.notify("The active adapter has no effort setting", vim.log.levels.INFO)
  end

  local function select_value(option)
    vim.ui.select(option.choices, {
      prompt = option.name,
      format_item = function(choice)
        return (choice == option.value and "* " or "  ") .. tostring(choice)
      end,
    }, function(choice)
      if not choice then
        return
      end
      chat.settings = chat.settings or {}
      chat.settings[option.key] = choice
      chat:apply_settings(chat.settings)
      M.update(chat)
      utils.notify(("%s: %s"):format(option.name, tostring(choice)), vim.log.levels.INFO)
    end)
  end

  if #options == 1 then
    return select_value(options[1])
  end

  vim.ui.select(options, {
    prompt = "Effort settings",
    format_item = function(option)
      return ("%s: %s"):format(option.name, tostring(option.value or ""))
    end,
  }, select_value)
end

---@param chat CodeCompanion.Chat
---@param token string
---@return boolean
function M.insert_context(chat, token)
  local composer = chat.composer
  if not composer or not vim.api.nvim_buf_is_valid(composer.bufnr) then
    return false
  end
  if M.has_context(chat, token) then
    utils.notify("That context is already attached", vim.log.levels.INFO)
    return true
  end

  local row = vim.api.nvim_buf_line_count(composer.bufnr) - 1
  local line = vim.api.nvim_buf_get_lines(composer.bufnr, row, row + 1, false)[1] or ""
  local separator = line == "" and "" or " "
  vim.api.nvim_buf_set_text(composer.bufnr, row, #line, row, #line, { separator .. token })
  if vim.api.nvim_win_is_valid(composer.winnr) then
    vim.api.nvim_win_set_cursor(composer.winnr, { row + 1, #line + #separator + #token })
  end
  M.update(chat)
  return true
end

---@param chat CodeCompanion.Chat
---@param token string
---@return nil
function M.remove_context(chat, token)
  local composer = chat.composer
  if not composer or not vim.api.nvim_buf_is_valid(composer.bufnr) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(composer.bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    local start = line:find(token, 1, true)
    if start then
      local before = line:sub(1, start - 1):gsub("%s+$", "")
      local after = line:sub(start + #token):gsub("^%s+", "")
      local separator = (before ~= "" and after ~= "") and " " or ""
      lines[index] = before .. separator .. after
      break
    end
  end
  vim.api.nvim_buf_set_lines(composer.bufnr, 0, -1, false, lines)
  M.update(chat)
end

---@param chat CodeCompanion.Chat
---@return nil
function M.open(chat)
  if chat._session_picker and chat._session_picker.active then
    return
  end
  if not is_available(chat) then
    return
  end

  if chat.composer and vim.api.nvim_win_is_valid(chat.composer.winnr) then
    update_window(chat)
    render_controls(chat)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undolevels = -1
  if chat._composer_draft then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, chat._composer_draft)
  end

  local ok, winnr = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "win",
    win = chat.ui.winnr,
    anchor = "SW",
    row = vim.api.nvim_win_get_height(chat.ui.winnr) - 1,
    col = 0,
    width = vim.api.nvim_win_get_width(chat.ui.winnr),
    height = 4,
    border = "rounded",
    title = " Composer ",
    title_pos = "left",
    style = "minimal",
  })
  if not ok or not winnr then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end
  vim.wo[winnr].cursorline = false
  vim.wo[winnr].number = false
  vim.wo[winnr].relativenumber = false
  vim.wo[winnr].signcolumn = "no"

  chat.composer = { bufnr = bufnr, winnr = winnr }
  vim.keymap.set({ "i", "n" }, "<C-s>", function()
    M.submit(chat)
  end, { buffer = bufnr, desc = "Send chat message" })
  vim.keymap.set("n", "<CR>", function()
    M.submit(chat)
  end, { buffer = bufnr, desc = "Send chat message" })
  vim.keymap.set("i", "<S-CR>", "<CR>", { buffer = bufnr, desc = "Insert a newline" })
  vim.keymap.set("i", "<S-Enter>", "<CR>", { buffer = bufnr, desc = "Insert a newline" })
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    chat._composer_draft = nil
    vim.cmd("stopinsert")
  end, { buffer = bufnr, desc = "Clear the draft" })
  vim.keymap.set("n", "g+", function()
    require("codecompanion.interactions.chat.keymaps").attach_context.callback(chat)
  end, { buffer = bufnr, desc = "Attach context" })
  vim.keymap.set("n", "ga", function()
    require("codecompanion.interactions.chat.keymaps").change_adapter.callback(chat)
  end, { buffer = bufnr, desc = "Change model" })
  vim.keymap.set("n", "gO", function()
    require("codecompanion.interactions.chat.keymaps").agent_options.callback(chat)
  end, { buffer = bufnr, desc = "Change agent option" })
  vim.keymap.set("n", "gty", function()
    require("codecompanion.interactions.chat.keymaps").yolo_mode.callback(chat)
  end, { buffer = bufnr, desc = "Change permissions" })
  vim.keymap.set("n", "gF", function()
    require("codecompanion.interactions.chat.keymaps").changed_files.callback(chat)
  end, { buffer = bufnr, desc = "Review changed files" })

  render_controls(chat)
  if vim.api.nvim_win_is_valid(winnr) then
    vim.api.nvim_set_current_win(winnr)
    vim.cmd("startinsert")
  end
end

---@param chat CodeCompanion.Chat
---@return nil
function M.update(chat)
  if not is_available(chat) then
    M.close(chat)
    return
  end

  if chat.composer and vim.api.nvim_win_is_valid(chat.composer.winnr) then
    update_window(chat)
    render_controls(chat)
  else
    M.open(chat)
  end
end

---@param chat CodeCompanion.Chat
---@return nil
function M.setup(chat)
  if not config.interactions.chat.opts.composer_controls then
    return
  end

  vim.api.nvim_create_autocmd("User", {
    group = chat.aug,
    pattern = "CodeCompanionChatOpened",
    callback = function(args)
      if args.data and args.data.id == chat.id then
        vim.schedule(function()
          M.open(chat)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
    group = chat.aug,
    callback = function()
      M.update(chat)
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = chat.aug,
    callback = function(args)
      local closed_winnr = tonumber(args.match)
      if chat.composer and closed_winnr == chat.composer.winnr then
        chat.composer = nil
      elseif chat.ui and closed_winnr == chat.ui.winnr then
        M.close(chat)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = chat.aug,
    buffer = chat.bufnr,
    callback = function()
      vim.schedule(function()
        if not is_available(chat) then
          M.close(chat)
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = chat.aug,
    pattern = { "CodeCompanionChatClosed", "CodeCompanionChatHidden" },
    callback = function(args)
      if args.data and args.data.id == chat.id then
        M.close(chat)
      end
    end,
  })
  chat:add_callback("on_completed", M.open)
end

return M
