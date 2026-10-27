local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        _G.Metrics = require("codecompanion.interactions.chat.acp.metrics")
      ]])
    end,
    post_once = child.stop,
  },
})

T["Context metrics"] = new_set()

T["Context metrics"]["syncs the token count and context size from a usage update"] = function()
  local result = child.lua([[
    local refreshed = 0
    local chat = {
      refresh_token_count = function()
        refreshed = refreshed + 1
      end,
    }

    _G.Metrics.sync(chat, { sessionUpdate = "usage_update", used = 1200, size = 200000 })

    return { tokens = chat.tokens, context_size = chat.context_size, refreshed = refreshed }
  ]])

  h.eq(1200, result.tokens)
  h.eq(200000, result.context_size)
  h.eq(1, result.refreshed)
end

T["Context metrics"]["reads the context state alias"] = function()
  local result = child.lua([[
    local chat = { refresh_token_count = function() end }
    _G.Metrics.sync(chat, {
      sessionUpdate = "context_state",
      context_state = { used = 900, size = 128000 },
    })
    return { tokens = chat.tokens, context_size = chat.context_size }
  ]])

  h.eq(900, result.tokens)
  h.eq(128000, result.context_size)
end

T["Context metrics"]["leaves the chat alone when the update has no usage"] = function()
  local result = child.lua([[
    local refreshed = 0
    local chat = {
      tokens = 42,
      refresh_token_count = function()
        refreshed = refreshed + 1
      end,
    }

    _G.Metrics.sync(chat, { sessionUpdate = "usage_update" })

    return { tokens = chat.tokens, refreshed = refreshed }
  ]])

  h.eq(42, result.tokens)
  h.eq(0, result.refreshed)
end

T["Context metrics"]["shows the used and total tokens in the default formatter"] = function()
  local result = child.lua([[
    local formatter = require("codecompanion.config").display.chat.token_count
    return {
      with_context = formatter(1200, nil, 200000),
      without_context = formatter(1200, nil),
    }
  ]])

  h.eq(" (1200/200000 tokens)", result.with_context)
  h.eq(" (1200 tokens)", result.without_context)
end

return T
