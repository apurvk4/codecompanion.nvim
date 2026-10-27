local Activity = require("codecompanion.interactions.chat.ui.activity")
local extract_text = require("codecompanion.acp.prompt_builder").extract_text

local M = {}

local STATUS = {
  in_progress = "running",
  completed = "success",
  failed = "error",
  cancelled = "cancelled",
}

---@param compaction_id string
---@return string
local function card_id(compaction_id)
  return "compaction:" .. compaction_id
end

---@param text string
---@return string[]
local function text_lines(text)
  return vim.split(text, "\n", { plain = true })
end

---Turn the summary content blocks into the lines shown on the card
---@param summary any
---@return string[]
local function summary_lines(summary)
  if summary == nil or summary == vim.NIL or (type(summary) == "table" and #summary == 0) then
    return {}
  end

  local lines = {}
  for _, block in ipairs(summary) do
    local text = extract_text(block)
    if text and text ~= "" then
      vim.list_extend(lines, text_lines(text))
    end
  end
  return lines
end

---@param chat CodeCompanion.Chat
---@param params table
---@return CodeCompanion.Chat.UI.ActivityCard|nil
local function card(chat, params)
  return Activity.get(chat, card_id(params.compactionId))
end

---Append a summary chunk to a compaction's card
---@param chat CodeCompanion.Chat
---@param params table
---@return nil
function M.append_chunk(chat, params)
  if type(params.compactionId) ~= "string" or params.compactionId == "" then
    return
  end

  local existing = card(chat, params)
  local output = existing and vim.deepcopy(existing.output) or {}
  local text = extract_text(params.content)
  if text and text ~= "" then
    vim.list_extend(output, text_lines(text))
  end

  Activity.upsert(chat, {
    id = card_id(params.compactionId),
    title = "Context compaction",
    kind = "compaction",
    status = existing and existing.status or "running",
    output = output,
    expand = true,
  })
end

---Apply a compaction update to its card
---@param chat CodeCompanion.Chat
---@param params table
---@return nil
function M.update(chat, params)
  if type(params.compactionId) ~= "string" or params.compactionId == "" then
    return
  end

  local existing = card(chat, params)
  local output = existing and vim.deepcopy(existing.output) or {}

  if params.summary ~= nil then
    output = summary_lines(params.summary)
  end

  if type(params.error) == "string" and params.error ~= "" then
    vim.list_extend(output, text_lines(params.error))
  end

  Activity.upsert(chat, {
    id = card_id(params.compactionId),
    title = "Context compaction",
    kind = "compaction",
    status = STATUS[params.status] or "running",
    output = output,
    expand = true,
  })
end

---Handle a compaction session update
---@param chat CodeCompanion.Chat
---@param params table
---@return nil
function M.handle(chat, params)
  if params.sessionUpdate == "compaction_summary_chunk" then
    return M.append_chunk(chat, params)
  end
  return M.update(chat, params)
end

return M
