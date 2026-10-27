local h = require("tests.helpers")

local new_set = MiniTest.new_set

local child = MiniTest.new_child_neovim()
local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require('tests.helpers')
        chat, tools = h.setup_chat_buffer()
        -- End the loop after the tools, as the follow-up request would never be answered
        require("codecompanion.interactions.chat.agent_loop").after_tools = function(tools)
          tools:reset()
        end

        _G.output = nil
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["run_command tool"] = function()
  child.lua([[
    --require("tests.log")
    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = '{"cmd": "echo hello world"}',
        },
      },
    }
    tools:execute(chat, tool)
    vim.wait(200)
  ]])

  h.expect_screenshot(child.get_screenshot(), "tests/screenshots/interactions/chat/tools/builtin/run_command_tool")
end

T["run_command tool times out a long running command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("`sleep` isn't available on Windows")
  end

  child.lua([[
    local cfg = {
      interactions = {
        chat = {
          tools = {
            run_command = { opts = { timeout = 100 } }
          }
        }
      }
    }
    chat, tools = h.setup_chat_buffer(cfg)

    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = '{"cmd": "sleep 2"}',
        },
      },
    }
    tools:execute(chat, tool)
    vim.wait(10000, function()
      return #chat.messages > 1
    end, 25)
  ]])

  local output = child.lua_get("chat.messages[#chat.messages].content")
  h.expect_contains("timed out", output)
end

T["stopping the chat kills a running command"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("`sleep` isn't available on Windows")
  end

  child.lua([[
    _G.marker = vim.fn.tempname()

    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = string.format('{"cmd": "sleep 1 && touch %s"}', _G.marker),
        },
      },
    }
    tools:execute(chat, tool)
    _G.running = vim.wait(5000, function()
      return chat.tool_orchestrator ~= nil and chat.tool_orchestrator.current_job ~= nil
    end, 25)

    chat:stop()
    vim.wait(5000, function()
      return #chat.messages > 1
    end, 25)

    -- Outlive the command so that the marker would exist had it survived the stop
    vim.wait(1500)
  ]])

  h.eq(true, child.lua_get("_G.running"))
  h.eq(0, child.lua_get("vim.fn.filereadable(_G.marker)"))
  h.eq(vim.NIL, child.lua_get("chat.tool_orchestrator"))
  h.expect_contains("cancelled", child.lua_get("chat.messages[#chat.messages].content"))
end

T["sends a running command to the background and shares its output when it finishes"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("`sleep` isn't available on Windows")
  end

  child.lua([[
    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = '{"cmd": "sleep 0.3 && echo background-done"}',
        },
      },
    }
    tools:execute(chat, tool)

    _G.started = vim.wait(5000, function()
      return chat.tool_orchestrator ~= nil and chat.tool_orchestrator.current_job ~= nil
    end, 25)

    local Activity = require("codecompanion.interactions.chat.ui.activity")
    local card = Activity.cards(chat)[1]
    _G.card_id = card.id

    _G.backgrounded = Activity.background(chat, card.id)
    _G.card_after_background = { status = card.status, background = card.background }

    _G.delivered = vim.wait(5000, function()
      return #chat.messages > 2
    end, 25)
  ]])

  h.eq(true, child.lua_get("_G.started"))
  h.eq(true, child.lua_get("_G.backgrounded"))
  h.eq("running", child.lua_get("_G.card_after_background.status"))
  h.eq(true, child.lua_get("_G.card_after_background.background"))
  h.eq(true, child.lua_get("_G.delivered"))

  local messages = child.lua_get([[
    table.concat(vim.tbl_map(function(m)
      return type(m.content) == "string" and m.content or ""
    end, chat.messages), "\n")
  ]])
  h.expect_contains("running in the background", messages)
  h.expect_contains("background-done", messages)

  local card = child.lua_get([[
    (function()
      local c = require("codecompanion.interactions.chat.ui.activity").get(chat, _G.card_id)
      return { status = c.status, background = c.background, job = c.job }
    end)()
  ]])
  h.eq("success", card.status)
  h.is_false(card.background)
  h.eq(nil, card.job)
end

T["stops a backgrounded command without sharing its output"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("`sleep` isn't available on Windows")
  end

  child.lua([[
    _G.marker = vim.fn.tempname()

    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = string.format('{"cmd": "sleep 1 && touch %s"}', _G.marker),
        },
      },
    }
    tools:execute(chat, tool)

    vim.wait(5000, function()
      return chat.tool_orchestrator ~= nil and chat.tool_orchestrator.current_job ~= nil
    end, 25)

    local Activity = require("codecompanion.interactions.chat.ui.activity")
    local card = Activity.cards(chat)[1]
    _G.card_id = card.id
    Activity.background(chat, card.id)
    _G.message_count = #chat.messages

    Activity.stop(chat, card.id)
    _G.stopped = vim.wait(5000, function()
      return card.status == "cancelled"
    end, 25)

    -- Outlive the command so the marker would exist had it survived the stop
    vim.wait(1500)
  ]])

  h.eq(true, child.lua_get("_G.stopped"))
  h.eq(child.lua_get("_G.message_count"), child.lua_get("#chat.messages"))
  h.eq(0, child.lua_get("vim.fn.filereadable(_G.marker)"))
end

T["does not offer backgrounding when the tool disables it"] = function()
  if vim.fn.has("win32") == 1 then
    MiniTest.skip("`sleep` isn't available on Windows")
  end

  child.lua([[
    local cfg = {
      interactions = {
        chat = {
          tools = {
            run_command = { opts = { background = { enabled = false } } }
          }
        }
      }
    }
    chat, tools = h.setup_chat_buffer(cfg)

    local tool = {
      {
        ["function"] = {
          name = "run_command",
          arguments = '{"cmd": "sleep 1"}',
        },
      },
    }
    tools:execute(chat, tool)

    vim.wait(5000, function()
      return chat.tool_orchestrator ~= nil and chat.tool_orchestrator.current_job ~= nil
    end, 25)

    local Activity = require("codecompanion.interactions.chat.ui.activity")
    local card = Activity.cards(chat)[1]
    _G.actions = vim.tbl_map(function(action)
      return action.label
    end, Activity.actions_for(card, chat))

    chat:stop()
    vim.wait(5000, function()
      return #chat.messages > 1
    end, 25)
  ]])

  h.is_false(vim.tbl_contains(child.lua_get("_G.actions"), "Send to background"))
  h.is_true(vim.tbl_contains(child.lua_get("_G.actions"), "Stop command"))
end

T["Windows"] = new_set()

T["Windows"]["run_command handles Windows pipe command with empty string argument"] = function()
  -- Skip on non-Windows systems
  if vim.fn.has("win32") == 0 then
    MiniTest.skip("Skipping Windows specific test")
  end

  child.lua([[
    local h = require("tests.helpers")

    -- Mock vim.system to execute real command but not call out_cb
    local command_results = {}
    local original_system = vim.system
    vim.system = function(args, opts, callback)
      -- Execute the real command but capture the result instead of calling the callback
      original_system(args, opts, function(result)
        table.insert(command_results, result)
        -- Don't call the original callback - we'll handle the result in the test
      end)
    end

    -- Use the actual run_command tool
    local cfg = {
      interactions = {
        chat = {
          tools = {
            run_command = { enabled = true }
          }
        }
      }
    }

    local chat, tools = h.setup_chat_buffer(cfg)
    _G.chat, _G.tools, _G.command_results = chat, tools, command_results

    -- Simulate LLM calling run_command with pipe and find command that has empty string argument
    local calls = {
      {
        ["function"] = {
          name = "run_command",
          -- Use full path to find.exe, since I know developers
          -- who have added a POSIX find.exe earlier in their PATH
          -- Using find.exe to explicitly pass in an empty argument
          -- which needs to make it AS an empty argument and not
          -- overly escaped or overly quoted strings
          arguments = '{"cmd": "echo hello there | %windir%\\\\System32\\\\find.exe /c /v \\"\\"", "flag": null}'
        }
      },
    }

    _G.tools:execute(_G.chat, calls)
    vim.wait(1000) -- Give more time for the real command to execute

    -- Restore original vim.system
    vim.system = original_system
  ]])

  -- Verify the actual command execution was successful and produced expected output
  local command_results = child.lua_get("_G.command_results")
  h.eq(#command_results, 1)

  local result = command_results[1]
  h.eq(result.code, 0) -- Command should succeed

  local lines = vim.split(result.stdout, "\r?\n", { plain = false })
  -- Remove leading empty lines
  while #lines > 0 and (lines[1] == "" or lines[1] == "\r") do
    table.remove(lines, 1)
  end
  -- Remove trailing empty lines
  while #lines > 0 and (lines[#lines] == "" or lines[#lines] == "\r") do
    table.remove(lines, #lines)
  end

  h.eq(lines, { "1" })
end

return T
