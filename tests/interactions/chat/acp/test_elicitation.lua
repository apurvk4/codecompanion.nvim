local h = require("tests.helpers")

local new_set = MiniTest.new_set
local child = MiniTest.new_child_neovim()

local T = new_set({
  hooks = {
    pre_case = function()
      h.child_start(child)
      child.lua([[
        _G.Elicitation = require("codecompanion.interactions.chat.acp.elicitation")
        _G.asked = {}
        _G.respond = function(response)
          table.insert(_G.asked, response)
        end
      ]])
    end,
    post_once = child.stop,
  },
})

T["Elicitation forms"] = new_set()

T["Elicitation forms"]["collects a string and a titled enum"] = function()
  local result = child.lua([[
    vim.ui.input = function(_, callback)
      callback("Apurv")
    end
    vim.ui.select = function(options, _, callback)
      callback(options[1])
    end

    _G.Elicitation.request(nil, {
      id = 1,
      respond = _G.respond,
      params = {
        mode = "form",
        message = "Tell me about you",
        requestedSchema = {
          type = "object",
          properties = {
            name = { type = "string", title = "Name" },
            colour = {
              type = "string",
              title = "Favourite colour",
              enum = { "red", "blue" },
            },
          },
          required = { "name" },
        },
      },
    })

    return _G.asked[1]
  ]])

  h.eq("accept", result.action)
  h.eq("Apurv", result.content.name)
  h.eq("red", result.content.colour)
end

T["Elicitation forms"]["keeps a false boolean answer"] = function()
  local result = child.lua([[
    vim.ui.select = function(options, _, callback)
      callback(options[2])
    end

    _G.Elicitation.request(nil, {
      id = 2,
      respond = _G.respond,
      params = {
        mode = "form",
        message = "Are you sure?",
        requestedSchema = {
          type = "object",
          properties = { sure = { type = "boolean", title = "Sure?" } },
        },
      },
    })

    return _G.asked[1]
  ]])

  h.eq("accept", result.action)
  h.eq(false, result.content.sure)
end

T["Elicitation forms"]["collects a multi-select array"] = function()
  local result = child.lua([[
    local calls = 0
    vim.ui.select = function(options, _, callback)
      calls = calls + 1
      if calls <= #options - 1 then
        callback(options[calls])
      else
        callback(options[#options])
      end
    end

    _G.Elicitation.request(nil, {
      id = 3,
      respond = _G.respond,
      params = {
        mode = "form",
        message = "Pick some tags",
        requestedSchema = {
          type = "object",
          properties = {
            tags = {
              type = "array",
              title = "Tags",
              items = { enum = { "one", "two" } },
            },
          },
        },
      },
    })

    return _G.asked[1]
  ]])

  h.eq("accept", result.action)
  h.eq({ "one", "two" }, result.content.tags)
end

T["Elicitation forms"]["cancels when a required answer is left blank"] = function()
  local result = child.lua([[
    vim.ui.input = function(_, callback)
      callback(nil)
    end

    _G.Elicitation.request(nil, {
      id = 4,
      respond = _G.respond,
      params = {
        mode = "form",
        message = "Tell me about you",
        requestedSchema = {
          type = "object",
          properties = { name = { type = "string", title = "Name" } },
          required = { "name" },
        },
      },
    })

    return _G.asked[1]
  ]])

  h.eq("cancel", result.action)
  h.eq(nil, result.content)
end

T["Elicitation forms"]["omits an optional answer left blank"] = function()
  local result = child.lua([[
    local answers = { "", "yes please" }
    vim.ui.input = function(_, callback)
      callback(table.remove(answers, 1))
    end

    _G.Elicitation.request(nil, {
      id = 5,
      respond = _G.respond,
      params = {
        mode = "form",
        message = "Anything else?",
        requestedSchema = {
          type = "object",
          properties = {
            nickname = { type = "string", title = "Nickname" },
            notes = { type = "string", title = "Notes" },
          },
        },
      },
    })

    return _G.asked[1]
  ]])

  h.eq("accept", result.action)
  h.eq(nil, result.content.nickname)
  h.eq("yes please", result.content.notes)
end

return T
