local M = {}

---Read the context window metrics from a usage update
---@param update table
---@return number|nil used, number|nil size
local function read_metrics(update)
  local used, size = update.used, update.size
  local state = update.context_state

  if type(state) == "table" then
    used = used or state.used
    size = size or state.size
  end

  -- NOTE: Some agents report the context window under their own keys
  used = used or update.used_tokens or update.usedTokens
  size = size or update.max_tokens or update.maxTokens

  return tonumber(used), tonumber(size)
end

---Sync the chat's token count with the context window the agent reports
---@param chat CodeCompanion.Chat
---@param update table
---@return nil
function M.sync(chat, update)
  local used, size = read_metrics(update)
  if not used then
    return
  end

  chat.tokens = used
  if size then
    chat.context_size = size
  end

  chat:refresh_token_count()
end

return M
