local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        _G.chat, _G.tools = h.setup_chat_buffer()
        _G.Activity = require("codecompanion.interactions.chat.ui.activity")

        _G.virt_lines = function(card)
          local ns = vim.api.nvim_get_namespaces()["CodeCompanion-activity_cards"]
          local position = vim.api.nvim_buf_get_extmark_by_id(_G.chat.bufnr, ns, card.mark_id, { details = true })
          local lines = {}
          for _, line in ipairs((position[3] and position[3].virt_lines) or {}) do
            local chunks = {}
            for _, chunk in ipairs(line) do
              table.insert(chunks, chunk[1])
            end
            table.insert(lines, table.concat(chunks))
          end
          return lines
        end
      ]])
    end,
    post_case = function()
      child.lua([[
        _G.Activity.cleanup(_G.chat.bufnr)
        h.teardown_chat_buffer()
      ]])
    end,
    post_once = child.stop,
  },
})

T["Activity cards"] = new_set()

T["Activity cards"]["updates a card in place when the same id arrives"] = function()
  local result = child.lua([[
    local first = _G.Activity.upsert(_G.chat, {
      id = "call_1",
      title = "run_command: ls",
      status = "running",
    })
    local before = vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, true)

    local second = _G.Activity.upsert(_G.chat, {
      id = "call_1",
      title = "run_command: ls",
      status = "success",
      output = { "one", "two" },
    })
    local after = vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, true)

    _G.Activity.toggle(_G.chat, "call_1")
    local expanded_lines = _G.virt_lines(second)

    return {
      same_lines = vim.deep_equal(before, after),
      card_count = #_G.Activity.cards(_G.chat),
      status = second.status,
      collapsed = not second.expanded and true or false,
      output = second.output,
      expanded_lines = expanded_lines,
      first_id = first.id,
      second_id = second.id,
    }
  ]])

  h.is_true(result.same_lines)
  h.eq(1, result.card_count)
  h.eq("success", result.status)
  h.eq({ "one", "two" }, result.output)
  h.eq(result.first_id, result.second_id)
  h.expect_contains("│ one", table.concat(result.expanded_lines, "\n"))
  h.expect_contains("│ two", table.concat(result.expanded_lines, "\n"))
end

T["Activity cards"]["appends a new card when the id is missing"] = function()
  local result = child.lua([[
    local first = _G.Activity.upsert(_G.chat, { title = "First", status = "running" })
    local second = _G.Activity.upsert(_G.chat, { title = "Second", status = "running" })

    return {
      card_count = #_G.Activity.cards(_G.chat),
      first_append_only = first.append_only,
      second_append_only = second.append_only,
      ids_differ = first.id ~= second.id,
    }
  ]])

  h.eq(2, result.card_count)
  h.is_true(result.first_append_only)
  h.is_true(result.second_append_only)
  h.is_true(result.ids_differ)
end

T["Activity cards"]["keeps running cards expanded and collapses completed cards"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "card",
      title = "run_command: ls",
      status = "running",
      output = { "out" },
    })
    local running_expanded = card.expanded

    _G.Activity.upsert(_G.chat, {
      id = "card",
      status = "success",
      output = { "out" },
    })
    local success_expanded = card.expanded

    _G.Activity.toggle(_G.chat, "card")
    local toggled_expanded = card.expanded

    return {
      running_expanded = running_expanded,
      success_expanded = success_expanded,
      toggled_expanded = toggled_expanded,
    }
  ]])

  h.is_true(result.running_expanded)
  h.is_false(result.success_expanded)
  h.is_true(result.toggled_expanded)
end

T["Activity cards"]["hides children when the parent collapses"] = function()
  local result = child.lua([[
    local parent = _G.Activity.upsert(_G.chat, { id = "parent", title = "Parent", status = "running" })
    local child = _G.Activity.upsert(_G.chat, {
      id = "child",
      title = "Child",
      status = "running",
      parent_id = "parent",
      output = { "child output" },
    })

    local expanded_lines = table.concat(_G.virt_lines(parent), "\n")

    _G.Activity.toggle(_G.chat, "parent")
    local collapsed_lines = table.concat(_G.virt_lines(parent), "\n")

    _G.Activity.toggle(_G.chat, "parent")
    local restored_lines = table.concat(_G.virt_lines(parent), "\n")

    return {
      children = parent.children,
      parent_id = child.parent_id,
      child_line = child.line_number,
      expanded_has_child = expanded_lines:find("Child", 1, true) ~= nil,
      collapsed_has_child = collapsed_lines:find("Child", 1, true) ~= nil,
      restored_has_child = restored_lines:find("Child", 1, true) ~= nil,
    }
  ]])

  h.eq({ "child" }, result.children)
  h.eq("parent", result.parent_id)
  h.eq(nil, result.child_line)
  h.is_true(result.expanded_has_child)
  h.is_false(result.collapsed_has_child)
  h.is_true(result.restored_has_child)
end

T["Activity cards"]["renders an unknown parent at the top level"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "child",
      title = "Child",
      status = "running",
      parent_id = "missing",
    })

    return { parent_id = card.parent_id, line_number = card.line_number }
  ]])

  h.eq(nil, result.parent_id)
  h.not_eq(vim.NIL, result.line_number)
end

T["Activity cards"]["only offers process actions when a handle exists"] = function()
  local result = child.lua([[
    local plain = _G.Activity.upsert(_G.chat, {
      id = "plain",
      title = "Read: config.json",
      status = "running",
      external = true,
      kind = "read",
    })
    local plain_actions = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(plain, _G.chat))

    local terminal = vim.api.nvim_create_buf(false, true)
    local job = { kill = function() end }
    local command = _G.Activity.upsert(_G.chat, {
      id = "command",
      title = "run_command: ls",
      status = "running",
      job = job,
      terminal_bufnr = terminal,
    })
    local command_actions = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(command, _G.chat))

    local detached = _G.Activity.upsert(_G.chat, {
      id = "detached",
      title = "run_command: make test",
      status = "running",
      job = job,
      on_background = function() end,
    })
    local detached_actions = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(detached, _G.chat))

    return { plain = plain_actions, command = command_actions, detached = detached_actions }
  ]])

  h.is_false(vim.tbl_contains(result.plain, "Open terminal"))
  h.is_false(vim.tbl_contains(result.plain, "Send to background"))
  h.is_false(vim.tbl_contains(result.plain, "Stop command"))

  h.is_true(vim.tbl_contains(result.command, "Open terminal"))
  h.is_false(vim.tbl_contains(result.command, "Send to background"))
  h.is_true(vim.tbl_contains(result.command, "Stop command"))

  h.is_true(vim.tbl_contains(result.detached, "Send to background"))
  h.is_true(vim.tbl_contains(result.detached, "Stop command"))
end

T["Activity cards"]["offers the command snapshot only while its buffer exists"] = function()
  local result = child.lua([[
    _G.Activity.upsert(_G.chat, {
      id = "snapshot",
      title = "Execute: ls",
      status = "success",
      kind = "execute",
      external = true,
      output = { "a.txt" },
    })
    _G.Activity.set_snapshot(_G.chat, "snapshot", {
      command = "ls",
      output = { "a.txt" },
      status = "success",
    })

    local card = _G.Activity.get(_G.chat, "snapshot")
    local offered = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(card, _G.chat))

    vim.api.nvim_buf_delete(card.snapshot_bufnr, { force = true })
    local after_delete = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(card, _G.chat))

    return { offered = offered, after_delete = after_delete }
  ]])

  h.is_true(vim.tbl_contains(result.offered, "View command snapshot"))
  h.is_false(vim.tbl_contains(result.after_delete, "View command snapshot"))
end

T["Activity cards"]["stops a background command and updates the card"] = function()
  local result = child.lua([[
    local killed = false
    local job = {
      kill = function()
        killed = true
      end,
    }
    local card = _G.Activity.upsert(_G.chat, {
      id = "command",
      title = "run_command: sleep 10",
      status = "running",
      job = job,
      on_background = function() end,
    })

    local backgrounded = _G.Activity.background(_G.chat, "command")
    local stopped = _G.Activity.stop(_G.chat, "command")

    return {
      backgrounded = backgrounded,
      stopped = stopped,
      killed = killed,
      status = card.status,
      background = card.background,
      job = card.job,
    }
  ]])

  h.is_true(result.backgrounded)
  h.is_true(result.stopped)
  h.is_true(result.killed)
  h.eq("cancelled", result.status)
  h.is_false(result.background)
  h.eq(nil, result.job)
end

T["Activity cards"]["keeps the first error line visible when collapsed"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "failed",
      title = "run_command: false",
      status = "error",
      output = { "boom", "more detail" },
    })

    _G.Activity.toggle(_G.chat, "failed")
    local lines = table.concat(_G.virt_lines(card), "\n")

    return {
      expanded = card.expanded,
      has_error = lines:find("boom", 1, true) ~= nil,
      has_hidden = lines:find("lines hidden", 1, true) ~= nil,
    }
  ]])

  h.is_false(result.expanded)
  h.is_true(result.has_error)
  h.is_true(result.has_hidden)
end

T["Activity cards"]["shows the limitation for agent-owned commands"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "agent-command",
      title = "Execute: ls",
      status = "success",
      kind = "execute",
      external = true,
      output = { "a" },
    })
    _G.Activity.toggle(_G.chat, "agent-command")

    local lines = table.concat(_G.virt_lines(card), "\n")
    local actions = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(card, _G.chat))

    return {
      has_limitation = lines:find("No terminal or background handle is available", 1, true) ~= nil,
      actions = actions,
    }
  ]])

  h.is_true(result.has_limitation)
  h.is_false(vim.tbl_contains(result.actions, "Open terminal"))
  h.is_false(vim.tbl_contains(result.actions, "Send to background"))
  h.is_false(vim.tbl_contains(result.actions, "Stop command"))
end

T["Activity cards"]["does not reorder unrelated cards when a status changes"] = function()
  local result = child.lua([[
    _G.Activity.upsert(_G.chat, { id = "first", title = "First", status = "running" })
    _G.Activity.upsert(_G.chat, { id = "second", title = "Second", status = "running" })

    local before = vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, true)
    _G.Activity.upsert(_G.chat, {
      id = "first",
      status = "success",
      output = { "done" },
    })
    local after = vim.api.nvim_buf_get_lines(_G.chat.bufnr, 0, -1, true)

    local order = vim.tbl_map(function(card)
      return card.id
    end, _G.Activity.cards(_G.chat))

    return { same = vim.deep_equal(before, after), order = order }
  ]])

  h.is_true(result.same)
  h.eq({ "first", "second" }, result.order)
end

T["Activity cards"]["attributes output to the chat and card that produced it"] = function()
  local result = child.lua([[
    local other_chat = h.setup_chat_buffer()

    local first = _G.Activity.upsert(_G.chat, {
      id = "same",
      title = "First",
      status = "success",
      output = { "first output" },
    })
    local second = _G.Activity.upsert(other_chat, {
      id = "same",
      title = "Second",
      status = "success",
      output = { "second output" },
    })

    _G.Activity.cleanup(other_chat.bufnr)

    return { first = first.output, second = second.output }
  ]])

  h.eq({ "first output" }, result.first)
  h.eq({ "second output" }, result.second)
end

T["Activity cards"]["leaves a card running when the tool refuses to background"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "command",
      title = "run_command: make test",
      status = "running",
      job = { kill = function() end },
      on_background = function()
        return false
      end,
    })

    local backgrounded = _G.Activity.background(_G.chat, "command")

    return { backgrounded = backgrounded, background = card.background, status = card.status }
  ]])

  h.is_false(result.backgrounded)
  h.is_false(result.background)
  h.eq("running", result.status)
end

T["Activity cards"]["finishes a background command and keeps its output"] = function()
  local result = child.lua([[
    local card = _G.Activity.upsert(_G.chat, {
      id = "command",
      title = "run_command: make test",
      status = "running",
      job = { kill = function() end },
      background = true,
    })

    _G.Activity.complete_background(_G.chat, "command", {
      status = "success",
      output = { "all tests passed" },
    })

    local actions = vim.tbl_map(function(action)
      return action.label
    end, _G.Activity.actions_for(card, _G.chat))

    return {
      status = card.status,
      background = card.background,
      job = card.job,
      output = card.output,
      actions = actions,
    }
  ]])

  h.eq("success", result.status)
  h.is_false(result.background)
  h.eq(nil, result.job)
  h.eq({ "all tests passed" }, result.output)
  h.is_false(vim.tbl_contains(result.actions, "Stop command"))
  h.is_false(vim.tbl_contains(result.actions, "Send to background"))
end

T["Activity cards"]["kills a running command when the buffer is cleaned up"] = function()
  local result = child.lua([[
    local killed = false
    _G.Activity.upsert(_G.chat, {
      id = "command",
      title = "run_command: sleep 100",
      status = "running",
      job = {
        kill = function()
          killed = true
        end,
      },
    })

    _G.Activity.cleanup(_G.chat.bufnr)
    return { killed = killed, cards = #_G.Activity.cards(_G.chat) }
  ]])

  h.is_true(result.killed)
  h.eq(0, result.cards)
end

return T
