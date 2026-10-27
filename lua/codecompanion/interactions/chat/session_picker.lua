local config = require("codecompanion.config")
local sessions = require("codecompanion.interactions.chat.sessions")
local utils = require("codecompanion.utils")

local M = {}

---@param chat CodeCompanion.Chat
---@return table[]
function M.get_entries(chat)
  local entries = { { kind = "new", label = "＋  New Chat", load_capable = false } }

  -- HTTP sessions with error handling for deleted/corrupted files
  local ok, http_sessions = pcall(sessions.list)
  if ok then
    for _, session in ipairs(http_sessions) do
      if session.meta and session.meta.saved_at then
        local saved_at = session.meta.saved_at
        local relative = saved_at and (utils.make_relative(saved_at) .. " ago") or ""
        table.insert(entries, {
          kind = "http",
          label = string.format("%s  %s", session.meta.title or session.stem, relative),
          session = session,
          load_capable = true,
        })
      else
        -- Deleted/corrupted session - show warning
        utils.notify("Skipped deleted/corrupted session: " .. (session.stem or "unknown"), vim.log.levels.WARN)
      end
    end
  else
    utils.notify("Failed to list HTTP sessions: " .. tostring(http_sessions), vim.log.levels.ERROR)
  end

  -- ACP sessions with error handling
  local connection = chat.acp_connection
  if connection and connection:can_list_sessions() and connection:can_load_session() then
    local acp_ok, acp_sessions = pcall(connection.session_list, connection, { max_sessions = 500 })
    if acp_ok then
      for _, session in ipairs(acp_sessions) do
        local title = session.title or session.sessionId
        local updated_at = session.updatedAt and utils.timestamp_from_iso(session.updatedAt)
        local relative = updated_at and (utils.make_relative(updated_at) .. " ago ") or ""
        table.insert(entries, {
          kind = "acp",
          label = string.format("%s%s  [%s]", relative, title, chat.adapter.formatted_name or chat.adapter.name),
          session = session,
          load_capable = true,
        })
      end
    else
      utils.notify("ACP session list error: " .. tostring(acp_sessions), vim.log.levels.ERROR)
    end
  end

  return entries
end

---@param chat CodeCompanion.Chat
---@param entry table
---@return nil
local function restore_acp_session(chat, entry)
  local updates = {}
  local ok = chat.acp_connection:load_session(entry.session.sessionId, {
    on_session_update = function(update)
      table.insert(updates, update)
    end,
  })

  if not ok then
    return utils.notify("Failed to load agent session", vim.log.levels.ERROR)
  end

  require("codecompanion.interactions.chat.acp.commands").link_buffer_to_session(
    chat.bufnr,
    chat.acp_connection.session_id
  )
  require("codecompanion.interactions.chat.acp.render").restore_session(chat, updates)
  if entry.session.title then
    chat:set_title(entry.session.title)
  end
  utils.fire("ACPChatRestored", {
    bufnr = chat.bufnr,
    id = chat.id,
    session_id = chat.acp_connection.session_id,
    title = chat.title,
  })
end

---@param picker table
---@return nil
local function restore_keymaps(picker)
  if picker.keymaps then
    picker.keymaps:restore()
    picker.keymaps = nil
  end
end

---@param chat CodeCompanion.Chat
---@return boolean
function M.open(chat)
  require("codecompanion.interactions.chat.composer_controls").close(chat)
  local entries = M.get_entries(chat)
  local bufnr = chat.bufnr
  local window = chat.ui:is_visible() and chat.ui.winnr or nil
  local picker = {
    active = true,
    entries = entries,
    keymaps = require("codecompanion.utils.keymaps").Override.new(bufnr),
    original_cursorline = window and vim.wo[window].cursorline,
    original_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    rows = {},
    window = window,
  }

  local function clear_adapter_listener()
    if picker.adapter_autocmd then
      pcall(vim.api.nvim_del_autocmd, picker.adapter_autocmd)
      picker.adapter_autocmd = nil
    end
  end

  -- Close picker when adapter changes, then re-open with new adapter's sessions
  local function on_adapter_changed()
    if picker.active then
      picker.active = false
      clear_adapter_listener()
      restore_keymaps(picker)
      -- Re-open picker with new adapter's sessions
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          M.open(chat)
        end
      end)
    end
  end

  -- Listen for adapter changes (triggered by ga keymap)
  picker.adapter_autocmd = vim.api.nvim_create_autocmd("User", {
    pattern = "ChatAdapter",
    callback = function(args)
      if args.data and args.data.bufnr == bufnr then
        on_adapter_changed()
      end
    end,
  })

  local lines = {
    "## Recent Chats",
    "",
    "Select a session with j/k and Enter · n for a new chat · q to close",
    "",
  }
  if #entries == 1 then
    table.insert(lines, "No previous chats yet.")
    table.insert(lines, "")
  end
  for _, entry in ipairs(entries) do
    table.insert(lines, entry.label)
    picker.rows[#lines] = entry
  end

  vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  if window then
    vim.wo[window].cursorline = true
  end
  chat._session_picker = picker

  local function restore_composer()
    if not picker.active then
      return
    end
    picker.active = false
    clear_adapter_listener()
    restore_keymaps(picker)
    if picker.window and vim.api.nvim_win_is_valid(picker.window) then
      vim.wo[picker.window].cursorline = picker.original_cursorline
    end
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, picker.original_lines)
      vim.api.nvim_set_option_value("modified", false, { buf = bufnr })
      if chat.ui:is_visible() then
        chat.ui:follow()
      end
    end
    require("codecompanion.interactions.chat.composer_controls").open(chat)
  end

  local function select_entry(entry)
    if not entry then
      return
    end

    restore_composer()
    if entry.kind == "new" then
      return
    end
    if entry.kind == "http" then
      local restored = sessions.load(entry.session.stem, { buffer_context = chat.buffer_context })
      local has_user_message = vim.iter(chat.messages):any(function(message)
        return message.role == config.constants.USER_ROLE and message.content ~= ""
      end)
      if restored and not has_user_message then
        chat:close()
      end
      return
    end

    restore_acp_session(chat, entry)
  end

  local function select_current()
    if not picker.active then
      return
    end
    select_entry(picker.rows[vim.api.nvim_win_get_cursor(0)[1]])
  end

  local function select_mouse()
    if not picker.active then
      return
    end
    local mouse = vim.fn.getmousepos()
    if not mouse.winid or not vim.api.nvim_win_is_valid(mouse.winid) then
      return
    end
    vim.api.nvim_set_current_win(mouse.winid)
    vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, 0 })
    select_entry(picker.rows[mouse.line])
  end

  picker.keymaps:set("<CR>", select_current, { desc = "Open selected chat session" })
  picker.keymaps:set("<LeftMouse>", select_mouse, { desc = "Open clicked chat session" })
  picker.keymaps:set("n", restore_composer, { desc = "Start a new chat" })
  picker.keymaps:set("q", restore_composer, { desc = "Close session history view" })
  picker.keymaps:set("<Esc>", restore_composer, { desc = "Close session history view" })

  if window then
    vim.api.nvim_win_set_cursor(window, { #lines - #entries + 1, 0 })
  end
  return true
end

return M
