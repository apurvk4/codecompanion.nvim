local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        _G.Terminal = require("codecompanion.interactions.chat.terminal")

        _G.real_termopen = vim.fn.termopen
        _G.use_real_terminal = function()
          vim.fn.termopen = _G.real_termopen
        end

        _G.chan_ids = 100
        vim.fn.termopen = function()
          _G.chan_ids = _G.chan_ids + 1
          return _G.chan_ids
        end

        _G.sent = {}
        vim.api.nvim_chan_send = function(chan_id, data)
          table.insert(_G.sent, { chan_id = chan_id, data = data })
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Terminal"] = new_set()

T["Terminal"]["creates a session in a split and sends the command to its shell"] = function()
  local result = child.lua([[
    local ok = _G.Terminal.run_command({ cmd = "echo hello", term_id = "agent" })

    return {
      ok = ok,
      sessions = _G.Terminal.sessions(),
      height = vim.api.nvim_win_get_height(0),
      sent = _G.sent,
    }
  ]])

  h.is_true(result.ok)
  h.eq({ "agent" }, result.sessions)
  h.eq(15, result.height)
  h.eq({ { chan_id = 101, data = "echo hello\r" } }, result.sent)
end

T["Terminal"]["reuses the session and its shell for a later command"] = function()
  local result = child.lua([[
    _G.Terminal.run_command({ cmd = "echo one", term_id = "agent" })
    local first_bufnr = vim.api.nvim_get_current_buf()
    local windows = #vim.api.nvim_list_wins()

    _G.Terminal.run_command({ cmd = "echo two", term_id = "agent" })

    return {
      first_bufnr = first_bufnr,
      second_bufnr = vim.api.nvim_get_current_buf(),
      windows_before = windows,
      windows_after = #vim.api.nvim_list_wins(),
      sent = _G.sent,
    }
  ]])

  h.eq(result.first_bufnr, result.second_bufnr)
  h.eq(result.windows_before, result.windows_after)
  h.eq("echo one\r", result.sent[1].data)
  h.eq("echo two\r", result.sent[2].data)
  h.eq(result.sent[1].chan_id, result.sent[2].chan_id)
end

T["Terminal"]["starts a fresh shell when the session's buffer has gone"] = function()
  local result = child.lua([[
    _G.Terminal.run_command({ cmd = "echo one", term_id = "agent" })
    local first_bufnr = vim.api.nvim_get_current_buf()

    vim.api.nvim_buf_delete(first_bufnr, { force = true })
    _G.Terminal.run_command({ cmd = "echo two", term_id = "agent" })

    return {
      first_bufnr = first_bufnr,
      second_bufnr = vim.api.nvim_get_current_buf(),
      sessions = _G.Terminal.sessions(),
      sent = _G.sent,
    }
  ]])

  h.not_eq(result.first_bufnr, result.second_bufnr)
  h.eq({ "agent" }, result.sessions)
  h.not_eq(result.sent[1].chan_id, result.sent[2].chan_id)
end

T["Terminal"]["switches to the chosen session's buffer"] = function()
  local result = child.lua([[
    _G.Terminal.run_command({ cmd = "echo one", term_id = "first" })
    local first_bufnr = vim.api.nvim_get_current_buf()

    _G.Terminal.run_command({ cmd = "echo two", term_id = "second" })
    local second_bufnr = vim.api.nvim_get_current_buf()

    vim.ui.select = function(items, _, on_choice)
      on_choice(items[1])
    end
    _G.Terminal.switch()

    return {
      first_bufnr = first_bufnr,
      second_bufnr = second_bufnr,
      current_bufnr = vim.api.nvim_get_current_buf(),
      offered = _G.Terminal.sessions(),
    }
  ]])

  h.eq({ "first", "second" }, result.offered)
  h.eq(result.first_bufnr, result.current_bufnr)
  h.not_eq(result.second_bufnr, result.current_bufnr)
end

T["Terminal"]["reports when there are no sessions to switch to"] = function()
  local messages = child.lua([[
    local notified = {}
    vim.notify = function(message)
      table.insert(notified, message)
    end

    _G.Terminal.switch()
    return notified
  ]])

  h.eq({ "No terminal sessions are open" }, messages)
end

T["Terminal"]["maps double escape to leave terminal mode"] = function()
  local mapping = child.lua([[
    _G.Terminal.run_command({ cmd = "echo hello", term_id = "agent" })
    local bufnr = vim.api.nvim_get_current_buf()

    return vim.fn.maparg("<Esc><Esc>", "t", false, true)
  ]])

  h.eq("<Esc><Esc>", mapping.lhs)
  h.eq("<C-\\><C-n>", mapping.rhs)
end

T["Terminal"]["runs a command without changing the current window or buffer"] = function()
  local result = child.lua([[
    _G.use_real_terminal()
    local window = vim.api.nvim_get_current_win()
    local buffer = vim.api.nvim_get_current_buf()

    local terminal_id = _G.Terminal.create({ command = "sh", args = { "-c", "printf 'hello\n'" } })
    vim.wait(2000, function()
      local output = _G.Terminal.output(terminal_id)
      return output ~= nil and output.exitStatus ~= nil
    end)

    local output = _G.Terminal.output(terminal_id)
    local terminal_buffer = _G.Terminal.buffer(terminal_id)
    local state = {
      terminal_id = terminal_id,
      same_window = vim.api.nvim_get_current_win() == window,
      same_buffer = vim.api.nvim_get_current_buf() == buffer,
      hidden = terminal_buffer ~= vim.api.nvim_get_current_buf(),
      output = output and output.output,
      truncated = output and output.truncated,
      exit_code = output and output.exitStatus and output.exitStatus.exitCode,
    }

    _G.Terminal.release(terminal_id)
    return state
  ]])

  h.is_true(result.terminal_id ~= nil)
  h.is_true(result.same_window)
  h.is_true(result.same_buffer)
  h.is_true(result.hidden)
  h.eq("hello", result.output)
  h.is_false(result.truncated)
  h.eq(0, result.exit_code)
end

T["Terminal"]["reports no exit status while the command runs"] = function()
  local result = child.lua([[
    _G.use_real_terminal()
    local terminal_id = _G.Terminal.create({ command = "sh", args = { "-c", "sleep 5" } })

    local running = _G.Terminal.output(terminal_id)
    _G.Terminal.kill(terminal_id)
    vim.wait(2000, function()
      local output = _G.Terminal.output(terminal_id)
      return output ~= nil and output.exitStatus ~= nil
    end)

    local stopped = _G.Terminal.output(terminal_id)
    local buffer_alive = vim.api.nvim_buf_is_valid(_G.Terminal.buffer(terminal_id))
    _G.Terminal.release(terminal_id)

    return {
      running_status = running and running.exitStatus,
      stopped_status = stopped and stopped.exitStatus,
      buffer_alive = buffer_alive,
    }
  ]])

  h.eq(nil, result.running_status)
  h.is_true(result.stopped_status ~= nil)
  h.is_true(result.buffer_alive)
end

T["Terminal"]["truncates output from the beginning at a UTF-8 boundary"] = function()
  local result = child.lua([[
    _G.use_real_terminal()
    local terminal_id = _G.Terminal.create({
      command = "sh",
      args = { "-c", "printf 'abcédef\n'" },
      output_byte_limit = 4,
    })
    vim.wait(2000, function()
      local output = _G.Terminal.output(terminal_id)
      return output ~= nil and output.exitStatus ~= nil
    end)

    local output = _G.Terminal.output(terminal_id)
    local state = { output = output and output.output, truncated = output and output.truncated }
    _G.Terminal.release(terminal_id)
    return state
  ]])

  h.eq("édef", result.output)
  h.is_true(result.truncated)
end

T["Terminal"]["deletes the buffer on release and rejects the ID afterwards"] = function()
  local result = child.lua([[
    _G.use_real_terminal()
    local terminal_id = _G.Terminal.create({ command = "sh", args = { "-c", "sleep 5" } })
    local bufnr = _G.Terminal.buffer(terminal_id)

    local released = _G.Terminal.release(terminal_id)
    local released_again = _G.Terminal.release(terminal_id)

    return {
      released = released,
      released_again = released_again,
      buffer_valid = vim.api.nvim_buf_is_valid(bufnr),
      output = _G.Terminal.output(terminal_id),
      kill = _G.Terminal.kill(terminal_id),
      sessions = _G.Terminal.sessions(),
    }
  ]])

  h.is_true(result.released)
  h.is_false(result.released_again)
  h.is_false(result.buffer_valid)
  h.eq(nil, result.output)
  h.is_false(result.kill)
  h.eq({}, result.sessions)
end

T["Terminal"]["releases only the terminals owned by a chat"] = function()
  local result = child.lua([[
    _G.use_real_terminal()
    local first = _G.Terminal.create({ command = "sh", args = { "-c", "sleep 5" }, owner = "chat-1" })
    local second = _G.Terminal.create({ command = "sh", args = { "-c", "sleep 5" }, owner = "chat-1" })
    local other = _G.Terminal.create({ command = "sh", args = { "-c", "sleep 5" }, owner = "chat-2" })

    _G.Terminal.release_for_owner("chat-1")
    local state = {
      first = _G.Terminal.output(first),
      second = _G.Terminal.output(second),
      other = _G.Terminal.output(other) ~= nil,
      sessions = _G.Terminal.sessions(),
    }

    _G.Terminal.release(other)
    return state
  ]])

  h.eq(nil, result.first)
  h.eq(nil, result.second)
  h.is_true(result.other)
  h.eq(1, #result.sessions)
end

return T
