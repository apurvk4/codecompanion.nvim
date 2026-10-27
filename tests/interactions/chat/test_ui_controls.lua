local h = require("tests.helpers")

local child = MiniTest.new_child_neovim()
local T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        _G.chat = h.setup_chat_buffer()
        _G.keymaps = require("codecompanion.interactions.chat.keymaps")
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["Chat UI controls"] = MiniTest.new_set()

T["Chat UI controls"]["shows the active model and approval mode in the bottom composer"] = function()
  child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
  ]])

  local display = child.lua([[
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    local composer = _G.chat.composer
    local extmarks = vim.api.nvim_buf_get_extmarks(composer.bufnr, -1, 0, -1, { details = true })
    local lines = {}
    for _, mark in ipairs(extmarks) do
      for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual_line) do
          table.insert(lines, chunk[1])
        end
      end
    end
    return table.concat(lines)
  ]])

  h.expect_contains("Model:", display)
  h.expect_contains("Permissions: Default / Ask", display)
  h.expect_contains("Attach context  g+", display)
end

T["Chat UI controls"]["submits the bottom composer through the chat buffer"] = function()
  local input = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    vim.api.nvim_buf_set_lines(_G.chat.composer.bufnr, 0, -1, false, { "Explain this function" })
    _G.chat.submit = function(chat)
      return vim.api.nvim_buf_get_lines(chat.bufnr, chat.header_line, -1, false)
    end
    return require("codecompanion.interactions.chat.composer_controls").submit(_G.chat)
  ]])

  h.eq({ "Explain this function" }, input)
end

T["Chat UI controls"]["attaches the current buffer context tag at the composer"] = function()
  child.lua([[
    vim.ui.select = function(items, _, callback)
      callback(items[1])
    end
    _G.keymaps.attach_context.callback(_G.chat)
    _G.last_line = vim.api.nvim_buf_get_lines(_G.chat.bufnr, -2, -1, false)[1]
    _G.prefix = require("codecompanion.triggers").mappings.editor_context
  ]])

  h.eq(true, child.lua_get([[_G.last_line:find(_G.prefix .. "{buffer}", 1, true) ~= nil]]))
end

T["Chat UI controls"]["attaches all open buffers through the native context marker"] = function()
  child.lua([[
    vim.ui.select = function(items, _, callback)
      callback(items[2])
    end
    _G.keymaps.attach_context.callback(_G.chat)
    _G.last_line = vim.api.nvim_buf_get_lines(_G.chat.bufnr, -2, -1, false)[1]
    _G.prefix = require("codecompanion.triggers").mappings.editor_context
  ]])

  h.eq(true, child.lua_get([[_G.last_line:find(_G.prefix .. "{buffers}", 1, true) ~= nil]]))
end

T["Chat UI controls"]["applies an advertised ACP configuration option"] = function()
  local result = child.lua([[
    local changed
    local connection = {
      get_config_options = function()
        return {
          {
            id = "thought_level",
            name = "Effort",
            type = "select",
            currentValue = "low",
            options = {
              { value = "low", name = "Low" },
              { value = "high", name = "High" },
            },
          },
        }
      end,
      set_config_option = function(_, id, value)
        changed = { id = id, value = value }
        return true
      end,
    }
    _G.chat.acp_connection = connection
    _G.chat.adapter.type = "acp"
    _G.chat.update_metadata = function() end
    vim.ui.select = function(items, opts, callback)
      local choice = opts.format_item and items[2] or items[1]
      callback(choice)
    end

    _G.keymaps.agent_options.callback(_G.chat)
    return changed
  ]])

  h.eq({ id = "thought_level", value = "high" }, result)
end

T["Chat UI controls"]["aggregates changed files by chat without mixing sessions"] = function()
  local result = child.lua([[
    local edited_files = require("codecompanion.interactions.shared.edited_files")
    edited_files.setup()

    local function record(edit)
      vim.api.nvim_exec_autocmds("User", {
        pattern = "CodeCompanionFileEdited",
        data = edit,
      })
    end

    record({
      path = "/tmp/changed.lua",
      tool = "edit_file",
      chat_id = 10,
      tool_call_id = "call-1",
      added = 3,
      removed = 1,
    })
    record({
      path = "/tmp/changed.lua",
      tool = "edit_file",
      chat_id = 10,
      tool_call_id = "call-2",
      added = 2,
      removed = 4,
    })
    record({
      path = "/tmp/other.lua",
      tool = "edit_file",
      chat_id = 11,
      tool_call_id = "call-3",
      added = 8,
      removed = 0,
    })

    return edited_files.for_chat(10)
  ]])

  h.eq(1, #result)
  h.eq("/tmp/changed.lua", result[1].path)
  h.eq(5, result[1].added)
  h.eq(5, result[1].removed)
end

T["Chat UI controls"]["renders its own changed-file summary above the prompt section"] = function()
  local result = child.lua([[
    require("codecompanion.interactions.shared.edited_files").setup()
    require("codecompanion.interactions.chat.changed_files").setup(_G.chat)
    vim.api.nvim_exec_autocmds("User", {
      pattern = "CodeCompanionFileEdited",
      data = {
        path = vim.fn.getcwd() .. "/changed.lua",
        tool = "edit_file",
        added = 4,
        removed = 2,
        chat_id = _G.chat.id,
        chat_bufnr = _G.chat.bufnr,
        tool_call_id = "changed-call",
      },
    })

    local extmarks = vim.api.nvim_buf_get_extmarks(_G.chat.bufnr, -1, 0, -1, { details = true })
    local display = {}
    for _, mark in ipairs(extmarks) do
      for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual_line) do
          table.insert(display, chunk[1])
        end
        table.insert(display, "\n")
      end
    end
    return table.concat(display)
  ]])

  h.expect_contains("Changed files  1  (+4 / -2)", result)
  h.expect_contains("changed.lua", result)
end

T["Chat UI controls"]["closes the composer window when the chat UI is hidden"] = function()
  child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    _G.composer_winnr = _G.chat.composer.winnr
    _G.chat.ui:hide()
  ]])

  local is_valid = child.lua_get([[vim.api.nvim_win_is_valid(_G.composer_winnr)]])
  local composer = child.lua_get([[_G.chat.composer]])
  h.eq(false, is_valid)
  h.eq(vim.NIL, composer)
end

T["Chat UI controls"]["DOES NOT error on WinResized when the chat window has closed"] = function()
  local ok = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    _G.composer_winnr = _G.chat.composer.winnr
    vim.api.nvim_win_close(_G.chat.ui.winnr, true)
    local success, _ = pcall(function()
      vim.api.nvim_exec_autocmds("WinResized", {})
    end)
    return success
  ]])

  local is_valid = child.lua_get([[vim.api.nvim_win_is_valid(_G.composer_winnr)]])
  local composer = child.lua_get([[_G.chat.composer]])
  h.eq(true, ok)
  h.eq(false, is_valid)
  h.eq(vim.NIL, composer)
end

T["Chat UI controls"]["closes the composer window when the chat is closed"] = function()
  child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    _G.composer_winnr = _G.chat.composer.winnr
    _G.chat:close()
  ]])

  local is_valid = child.lua_get([[vim.api.nvim_win_is_valid(_G.composer_winnr)]])
  local composer = child.lua_get([[_G.chat and _G.chat.composer or nil]])
  h.eq(false, is_valid)
  h.eq(vim.NIL, composer)
end

T["Chat UI controls"]["preserves the composer draft when the window closes and reopens"] = function()
  local lines = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    vim.api.nvim_buf_set_lines(_G.chat.composer.bufnr, 0, -1, false, { "Keep me" })
    local controls = require("codecompanion.interactions.chat.composer_controls")
    controls.close(_G.chat)
    controls.open(_G.chat)
    return vim.api.nvim_buf_get_lines(_G.chat.composer.bufnr, 0, -1, false)
  ]])

  h.eq({ "Keep me" }, lines)
end

T["Chat UI controls"]["clears the composer draft on Escape without submitting"] = function()
  child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)
    _G.chat.submit = function()
      _G.submitted = true
    end
    vim.api.nvim_buf_set_lines(_G.chat.composer.bufnr, 0, -1, false, { "draft" })
    vim.api.nvim_set_current_win(_G.chat.composer.winnr)
    vim.cmd("startinsert")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "mx", false)
  ]])

  h.eq({ "" }, child.lua_get("vim.api.nvim_buf_get_lines(_G.chat.composer.bufnr, 0, -1, false)"))
  h.eq(vim.NIL, child.lua_get("_G.submitted"))
end

T["Chat UI controls"]["shows the adapter effort setting and applies a new value"] = function()
  local result = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)

    _G.chat.adapter.schema.reasoning_effort = {
      order = 3,
      mapping = "parameters",
      type = "enum",
      default = "high",
      choices = { "high", "max" },
    }
    _G.chat.settings = _G.chat.settings or {}
    _G.chat.settings.reasoning_effort = "high"

    local controls = require("codecompanion.interactions.chat.composer_controls")
    controls.update(_G.chat)

    local function display()
      local lines = {}
      local extmarks = vim.api.nvim_buf_get_extmarks(_G.chat.composer.bufnr, -1, 0, -1, { details = true })
      for _, mark in ipairs(extmarks) do
        for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(virtual_line) do
            table.insert(lines, chunk[1])
          end
        end
      end
      return table.concat(lines)
    end

    local before = display()
    vim.ui.select = function(items, _, callback)
      callback(items[2])
    end
    _G.keymaps.agent_options.callback(_G.chat)
    return {
      after = display(),
      before = before,
      value = _G.chat.settings.reasoning_effort,
    }
  ]])

  h.expect_contains("Effort: high", result.before)
  h.expect_contains("Effort: max", result.after)
  h.eq("max", result.value)
end

T["Chat UI controls"]["attaches and removes context chips at the composer"] = function()
  local result = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)

    local controls = require("codecompanion.interactions.chat.composer_controls")
    local function display()
      local lines = {}
      local extmarks = vim.api.nvim_buf_get_extmarks(_G.chat.composer.bufnr, -1, 0, -1, { details = true })
      for _, mark in ipairs(extmarks) do
        for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
          for _, chunk in ipairs(virtual_line) do
            table.insert(lines, chunk[1])
          end
        end
      end
      return table.concat(lines)
    end

    vim.ui.select = function(items, _, callback)
      callback(items[1])
    end
    _G.keymaps.attach_context.callback(_G.chat)
    local attached = controls.attached_context(_G.chat)
    local chips = display()

    vim.ui.select = function(items, _, callback)
      callback(items[#items])
    end
    _G.keymaps.attach_context.callback(_G.chat)

    return {
      chips = chips,
      remaining = #controls.attached_context(_G.chat),
      token = attached[1] and attached[1].token,
    }
  ]])

  h.eq("#{buffer}", result.token)
  h.expect_contains("[buffer: current]", result.chips)
  h.eq(0, result.remaining)
end

T["Chat UI controls"]["labels the auto approval mode as Auto-approve safe actions"] = function()
  local display = child.lua([[
    _G.chat = h.setup_chat_buffer({
      interactions = {
        chat = {
          opts = { composer_controls = true },
        },
      },
    })
    vim.wait(100, function() return _G.chat.composer ~= nil end)

    require("codecompanion.interactions.chat.tools.approvals"):set_mode(_G.chat.bufnr, { mode = "auto" })
    local controls = require("codecompanion.interactions.chat.composer_controls")
    controls.update(_G.chat)

    local lines = {}
    local extmarks = vim.api.nvim_buf_get_extmarks(_G.chat.composer.bufnr, -1, 0, -1, { details = true })
    for _, mark in ipairs(extmarks) do
      for _, virtual_line in ipairs(mark[4].virt_lines or {}) do
        for _, chunk in ipairs(virtual_line) do
          table.insert(lines, chunk[1])
        end
      end
    end
    return table.concat(lines)
  ]])

  h.expect_contains("Permissions: Auto-approve safe actions", display)
end

return T
