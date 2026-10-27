local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        h = require("tests.helpers")
        _G.chat = h.setup_chat_buffer()
        _G.Compaction = require("codecompanion.interactions.chat.acp.compaction")
        _G.Activity = require("codecompanion.interactions.chat.ui.activity")
      ]])
    end,
    post_case = function()
      child.lua([[h.teardown_chat_buffer()]])
    end,
    post_once = child.stop,
  },
})

T["Compaction"] = new_set()

T["Compaction"]["renders a summary chunk on an expanded card"] = function()
  local result = child.lua([[
    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_summary_chunk",
      compactionId = "cmp_001",
      content = { type = "text", text = "## Retained context" },
    })

    local card = _G.Activity.cards(_G.chat)[1]
    return { title = card.title, status = card.status, expanded = card.expanded, output = card.output }
  ]])

  h.eq("Context compaction", result.title)
  h.eq("running", result.status)
  h.is_true(result.expanded)
  h.eq({ "## Retained context" }, result.output)
end

T["Compaction"]["appends chunks in receive order"] = function()
  local result = child.lua([[
    for _, text in ipairs({ "first", "second" }) do
      _G.Compaction.handle(_G.chat, {
        sessionUpdate = "compaction_summary_chunk",
        compactionId = "cmp_001",
        content = { type = "text", text = text },
      })
    end

    return _G.Activity.cards(_G.chat)[1].output
  ]])

  h.eq({ "first", "second" }, result)
end

T["Compaction"]["replaces the summary when the agent sends a completed update"] = function()
  local result = child.lua([[
    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_summary_chunk",
      compactionId = "cmp_001",
      content = { type = "text", text = "partial" },
    })

    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_update",
      compactionId = "cmp_001",
      status = "completed",
      summary = {
        { type = "text", text = "## Retained context\n\nThe user is building a client." },
      },
    })

    local card = _G.Activity.cards(_G.chat)[1]
    return { status = card.status, output = card.output }
  ]])

  h.eq("success", result.status)
  h.eq({ "## Retained context", "", "The user is building a client." }, result.output)
end

T["Compaction"]["clears the summary when the update sends null"] = function()
  local result = child.lua([[
    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_summary_chunk",
      compactionId = "cmp_001",
      content = { type = "text", text = "stale" },
    })

    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_update",
      compactionId = "cmp_001",
      status = "in_progress",
      summary = vim.NIL,
    })

    return _G.Activity.cards(_G.chat)[1].output
  ]])

  h.eq({}, result)
end

T["Compaction"]["shows why a compaction failed"] = function()
  local result = child.lua([[
    _G.Compaction.handle(_G.chat, {
      sessionUpdate = "compaction_update",
      compactionId = "cmp_001",
      status = "failed",
      error = "The agent ran out of context",
    })

    local card = _G.Activity.cards(_G.chat)[1]
    return { status = card.status, output = card.output }
  ]])

  h.eq("error", result.status)
  h.eq({ "The agent ran out of context" }, result.output)
end

T["Compaction"]["ignores updates without a compaction id"] = function()
  local result = child.lua([[
    _G.Compaction.handle(_G.chat, { sessionUpdate = "compaction_update", status = "completed" })
    return #_G.Activity.cards(_G.chat)
  ]])

  h.eq(0, result)
end

return T
