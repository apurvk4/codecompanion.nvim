local h = require("tests.helpers")

local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        vim.ui.select = function()
          error("The chat history view must not use a numeric vim.ui.select picker")
        end
        sessions = require("codecompanion.interactions.chat.sessions")
        sessions.list = function()
          return {
            { stem = "20261020T120000-fix-parser", meta = { title = "Fix parser", saved_at = os.time() - 60 } },
          }
        end
        sessions.load = function(stem, opts)
          _G.loaded_http = { stem = stem, buffer_context = opts.buffer_context }
          return {}
        end

        _G.bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(_G.bufnr, 0, -1, false, { "## Me", "" })
        _G.chat = {
          adapter = { type = "http", name = "test", formatted_name = "Test" },
          buffer_context = { bufnr = 1 },
          bufnr = _G.bufnr,
          messages = {},
          close = function() _G.chat_closed = true end,
          ui = {
            is_visible = function() return false end,
            follow = function() end,
          },
        }
      ]])
    end,
    post_case = function()
      child.lua([[
        package.loaded["codecompanion.interactions.chat.session_picker"] = nil
        package.loaded["codecompanion.interactions.chat.acp.commands"] = nil
        package.loaded["codecompanion.interactions.chat.acp.render"] = nil
        if vim.api.nvim_buf_is_valid(_G.bufnr) then
          vim.api.nvim_buf_delete(_G.bufnr, { force = true })
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Session picker"] = MiniTest.new_set()

T["Session picker"]["shows a new-chat choice and saved history"] = function()
  child.lua([[
    require("codecompanion.interactions.chat.session_picker").open(_G.chat)
  ]])

  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(_G.bufnr, 0, -1, false)]])
  h.eq("## Recent Chats", lines[1])
  h.eq("＋  New Chat", lines[5])
  h.eq(true, lines[6]:find("Fix parser", 1, true) ~= nil)
  h.eq(
    true,
    child.lua_get([[
    vim.tbl_contains(vim.tbl_map(function(map) return map.lhs end, vim.api.nvim_buf_get_keymap(_G.bufnr, "n")), "<CR>")
  ]])
  )
end

T["Session picker"]["shows an empty-history state instead of skipping the session screen"] = function()
  child.lua([[
    sessions.list = function() return {} end
    require("codecompanion.interactions.chat.session_picker").open(_G.chat)
  ]])

  local lines = child.lua_get([[vim.api.nvim_buf_get_lines(_G.bufnr, 0, -1, false)]])
  h.eq("No previous chats yet.", lines[5])
  h.eq("＋  New Chat", lines[7])
end

T["Session picker"]["keeps the fresh chat when New Chat is selected"] = function()
  child.lua([[
    require("codecompanion.interactions.chat.session_picker").open(_G.chat)
    vim.api.nvim_set_current_buf(_G.bufnr)
    vim.api.nvim_win_set_cursor(0, { 5, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
  ]])

  h.eq(vim.NIL, child.lua_get([[_G.loaded_http]]))
  h.eq(vim.NIL, child.lua_get([[_G.chat_closed]]))
  h.eq("## Me", child.lua_get("vim.api.nvim_buf_get_lines(_G.bufnr, 0, 1, false)[1]"))
end

T["Session picker"]["restores a saved HTTP session and closes the empty starter chat"] = function()
  child.lua([[
    require("codecompanion.interactions.chat.session_picker").open(_G.chat)
    vim.api.nvim_set_current_buf(_G.bufnr)
    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
  ]])

  h.eq("20261020T120000-fix-parser", child.lua_get([[_G.loaded_http.stem]]))
  h.eq({ bufnr = 1 }, child.lua_get([[_G.loaded_http.buffer_context]]))
  h.eq(true, child.lua_get([[_G.chat_closed]]))
end

T["Session picker"]["loads a selectable ACP session into the current chat"] = function()
  local result = child.lua([[
    _G.chat.adapter.type = "acp"
    _G.chat.acp_connection = {
      can_list_sessions = function() return true end,
      can_load_session = function() return true end,
      session_list = function()
        return { { sessionId = "agent-session", title = "Agent history" } }
      end,
      load_session = function(_, session_id, opts)
        _G.loaded_acp = session_id
        _G.chat.acp_connection.session_id = session_id
        opts.on_session_update({ sessionUpdate = "agent_message_chunk" })
        return true
      end,
    }
    package.loaded["codecompanion.interactions.chat.acp.commands"] = {
      link_buffer_to_session = function(_, session_id) _G.linked_acp = session_id end,
    }
    package.loaded["codecompanion.interactions.chat.acp.render"] = {
      restore_session = function(chat, updates)
        vim.api.nvim_buf_set_lines(chat.bufnr, 0, -1, false, { "Agent history", "", "Updated", updates[#updates] and updates[#updates].type or "" })
        _G.restored_update_count = #updates
      end,
    }
    _G.chat.set_title = function(_, title) _G.restored_title = title end

    require("codecompanion.interactions.chat.session_picker").open(_G.chat)
    vim.api.nvim_set_current_buf(_G.bufnr)
    vim.api.nvim_win_set_cursor(0, { 7, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "mx", false)
    return {
      loaded = _G.loaded_acp,
      linked = _G.linked_acp,
      updates = _G.restored_update_count,
      title = _G.restored_title,
      lines = vim.api.nvim_buf_get_lines(_G.bufnr, 0, -1, false),
    }
  ]])

  h.eq(
    true,
    vim.iter(result.lines):any(function(line)
      return line:find("Agent history", 1, true) ~= nil
    end)
  )
  h.eq("agent-session", result.loaded)
  h.eq("agent-session", result.linked)
  h.eq(1, result.updates)
  h.eq("Agent history", result.title)
end

T["Session picker"]["does not create an ACP session when the chat opens in deferred mode"] = function()
  local result = child.lua([[
    local previous_async = package.loaded["codecompanion.utils.async"]
    local previous_handler = package.loaded["codecompanion.interactions.chat.acp.handler"]
    local session_creations = 0
    local callback_called = false

    package.loaded["codecompanion.utils.async"] = {
      sync = function(callback)
        return function() callback() end
      end,
    }
    package.loaded["codecompanion.interactions.chat.acp.handler"] = {
      new = function()
        return {
          ensure_connection = function() return true end,
          ensure_session = function()
            session_creations = session_creations + 1
            return true
          end,
        }
      end,
    }

    require("codecompanion.interactions.chat.helpers").create_acp_connection(
      _G.chat,
      function() callback_called = true end,
      { defer_session = true }
    )
    vim.wait(100, function() return callback_called end)

    package.loaded["codecompanion.utils.async"] = previous_async
    package.loaded["codecompanion.interactions.chat.acp.handler"] = previous_handler
    return { session_creations = session_creations, callback_called = callback_called }
  ]])

  h.eq(0, result.session_creations)
  h.eq(true, result.callback_called)
end

T["Session picker"]["get_entries returns structured entries"] = MiniTest.new_set()

T["Session picker"]["get_entries returns structured entries"]["empty history returns only new-chat entry"] = function()
  local result = child.lua([[
    sessions.list = function() return {} end
    local entries = require("codecompanion.interactions.chat.session_picker").get_entries(_G.chat)
    return entries
  ]])

  h.eq(1, #result)
  h.eq("new", result[1].kind)
  h.eq("＋  New Chat", result[1].label)
  h.eq(false, result[1].load_capable)
end

T["Session picker"]["get_entries returns structured entries"]["only http sessions"] = function()
  local result = child.lua([[
    sessions.list = function()
      return {
        { stem = "session-one", meta = { title = "First Session", saved_at = os.time() - 100 } },
        { stem = "session-two", meta = { title = "Second Session", saved_at = os.time() - 200 } },
      }
    end
    local entries = require("codecompanion.interactions.chat.session_picker").get_entries(_G.chat)
    return entries
  ]])

  h.eq(3, #result)
  h.eq("new", result[1].kind)
  h.eq("http", result[2].kind)
  h.eq("session-one", result[2].session.stem)
  h.eq("First Session", result[2].session.meta.title)
  h.eq(true, result[2].load_capable)
  h.eq("http", result[3].kind)
  h.eq("session-two", result[3].session.stem)
  h.eq(true, result[3].load_capable)
end

T["Session picker"]["get_entries returns structured entries"]["only acp sessions"] = function()
  local result = child.lua([[
    sessions.list = function() return {} end
    _G.chat.acp_connection = {
      can_list_sessions = function() return true end,
      can_load_session = function() return true end,
      session_list = function()
        return {
          { sessionId = "acp-one", title = "ACP One", updatedAt = "2026-10-20T10:00:00Z" },
          { sessionId = "acp-two", title = "ACP Two", updatedAt = "2026-10-20T11:00:00Z" },
        }
      end,
    }
    local entries = require("codecompanion.interactions.chat.session_picker").get_entries(_G.chat)
    return entries
  ]])

  h.eq(3, #result)
  h.eq("new", result[1].kind)
  h.eq("acp", result[2].kind)
  h.eq("acp-one", result[2].session.sessionId)
  h.eq("ACP One", result[2].session.title)
  h.eq(true, result[2].load_capable)
  h.eq("acp", result[3].kind)
  h.eq("acp-two", result[3].session.sessionId)
  h.eq(true, result[3].load_capable)
end

T["Session picker"]["get_entries returns structured entries"]["mixed http and acp sessions"] = function()
  local result = child.lua([[
    sessions.list = function()
      return {
        { stem = "http-session", meta = { title = "HTTP Session", saved_at = os.time() - 50 } },
      }
    end
    _G.chat.acp_connection = {
      can_list_sessions = function() return true end,
      can_load_session = function() return true end,
      session_list = function()
        return { { sessionId = "acp-session", title = "ACP Session", updatedAt = "2026-10-20T12:00:00Z" } }
      end,
    }
    local entries = require("codecompanion.interactions.chat.session_picker").get_entries(_G.chat)
    return entries
  ]])

  h.eq(3, #result)
  h.eq("new", result[1].kind)
  h.eq("http", result[2].kind)
  h.eq("http-session", result[2].session.stem)
  h.eq(true, result[2].load_capable)
  h.eq("acp", result[3].kind)
  h.eq("acp-session", result[3].session.sessionId)
  h.eq(true, result[3].load_capable)
end

T["Session picker"]["get_entries returns structured entries"]["acp sessions absent when capabilities disabled"] = function()
  local result = child.lua([[
    sessions.list = function()
      return {
        { stem = "http-session", meta = { title = "HTTP Session", saved_at = os.time() - 50 } },
      }
    end
    _G.chat.acp_connection = {
      can_list_sessions = function() return false end,
      can_load_session = function() return true end,
      session_list = function()
        return { { sessionId = "acp-session", title = "ACP Session" } }
      end,
    }
    local entries = require("codecompanion.interactions.chat.session_picker").get_entries(_G.chat)
    return entries
  ]])

  h.eq(2, #result)
  h.eq("new", result[1].kind)
  h.eq("http", result[2].kind)
  h.eq(true, result[2].load_capable)

  -- Verify no acp entries exist
  local acp_count = 0
  for _, entry in ipairs(result) do
    if entry.kind == "acp" then
      acp_count = acp_count + 1
    end
  end
  h.eq(0, acp_count)
end

return T
