--[[
===============================================================================
    File:       codecompanion.interactions/chat/ui/activity.lua
-------------------------------------------------------------------------------
    Description:
      Renders running agent activity as cards.

      A card is one summary line in the chat buffer plus virtual lines for its
      captured output and any child activities. Output lives in virtual lines
      so expanding or collapsing a card never moves the transcript or the line
      numbers of other cards.
===============================================================================
--]]

local config = require("codecompanion.config")
local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local api = vim.api

local MAX_OUTPUT_LINES = 200

local M = {}

local NS = api.nvim_create_namespace("CodeCompanion-activity_cards")

---@class CodeCompanion.Chat.UI.ActivityCard
---@field id string
---@field title string
---@field status "running"|"success"|"error"|"cancelled"
---@field output string[]
---@field output_truncated boolean
---@field expanded boolean
---@field user_toggled boolean
---@field parent_id? string
---@field children string[]
---@field line_number? number 1-based line of the summary
---@field mark_id? number
---@field icon_id? number
---@field job? vim.SystemObj
---@field terminal_bufnr? number
---@field terminal_id? string
---@field snapshot_bufnr? number
---@field background boolean
---@field external boolean
---@field kind? string
---@field append_only boolean
---@field on_stop? fun()
---@field on_background? fun()
---@field depth? number

---@class CodeCompanion.Chat.UI.ActivityState
---@field cards table<string, CodeCompanion.Chat.UI.ActivityCard>
---@field order string[]
---@field next_id number

---@type table<number, CodeCompanion.Chat.UI.ActivityState>
local registry = {}

---@param status? string
---@return "running"|"success"|"error"|"cancelled"
local function normalise_status(status)
  if status == "completed" or status == "success" then
    return "success"
  end
  if status == "failed" or status == "error" then
    return "error"
  end
  if status == "cancelled" or status == "canceled" then
    return "cancelled"
  end
  return "running"
end

---@param status string
---@return string
local function icon_status(status)
  if status == "success" then
    return "completed"
  end
  if status == "error" or status == "cancelled" then
    return "failed"
  end
  return "in_progress"
end

---@param status string
---@return string
local function status_icon(status)
  local icons = config.display.chat.icons
  if status == "success" then
    return icons.tool_success or "✅"
  end
  if status == "error" or status == "cancelled" then
    return icons.tool_failure or "❌"
  end
  return icons.tool_in_progress or "⚡"
end

---@param status string
---@return boolean
local function default_expanded(status)
  return status ~= "success"
end

---Flatten strings and nested tables into display lines
---@param value any
---@param lines? string[]
---@return string[]
local function flatten_output(value, lines)
  lines = lines or {}

  if type(value) == "string" then
    vim.list_extend(lines, vim.split(value, "\n", { plain = true }))
  elseif type(value) == "table" then
    for _, item in ipairs(value) do
      flatten_output(item, lines)
    end
  end

  return lines
end

---@param output any
---@return string[]
---@return boolean truncated
local function normalise_output(output)
  if output == nil then
    return {}, false
  end

  local lines = flatten_output(output)

  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end

  if #lines <= MAX_OUTPUT_LINES then
    return lines, false
  end

  local truncated = vim.list_slice(lines, 1, MAX_OUTPUT_LINES)
  return truncated, true
end

---@param bufnr number
---@return CodeCompanion.Chat.UI.ActivityState
local function state_for(bufnr)
  local state = registry[bufnr]
  if not state then
    state = { cards = {}, order = {}, next_id = 0 }
    registry[bufnr] = state
  end
  return state
end

---@param card CodeCompanion.Chat.UI.ActivityCard
---@param cards table<string, CodeCompanion.Chat.UI.ActivityCard>
---@param lines table
---@param indent string
local function render_output(card, cards, lines, indent)
  if #card.output == 0 then
    return
  end

  if not card.expanded then
    if card.status == "error" then
      table.insert(lines, { { indent .. "│ " .. (card.output[1] or ""), "CodeCompanionChatToolFailure" } })
    end
    table.insert(lines, { { indent .. "… " .. #card.output .. " lines hidden (gA to expand)", "Comment" } })
    return
  end

  for _, line in ipairs(card.output) do
    table.insert(lines, { { indent .. "│ " .. line, "CodeCompanionChatToolText" } })
  end

  if card.output_truncated then
    table.insert(lines, { { indent .. "… output truncated", "Comment" } })
  end
end

---@param card CodeCompanion.Chat.UI.ActivityCard
---@param cards table<string, CodeCompanion.Chat.UI.ActivityCard>
---@param lines table
---@param indent string
local function render_children(card, cards, lines, indent)
  for _, child_id in ipairs(card.children) do
    local child = cards[child_id]
    if child then
      table.insert(lines, {
        { indent .. status_icon(child.status) .. " " .. child.title, "CodeCompanionChatToolText" },
        { " [" .. child.status .. "]", "Comment" },
      })

      if child.expanded then
        render_output(child, cards, lines, indent .. "  ")
        render_children(child, cards, lines, indent .. "  ")
      end
    end
  end
end

---Build the virtual lines shown beneath a card's summary
---@param card CodeCompanion.Chat.UI.ActivityCard
---@param cards table<string, CodeCompanion.Chat.UI.ActivityCard>
---@return table[]
local function virtual_lines(card, cards)
  local lines = {}

  render_output(card, cards, lines, "  ")
  if card.expanded then
    render_children(card, cards, lines, "  ")
  end

  if card.external and card.kind == "execute" then
    table.insert(lines, {
      { "  No terminal or background handle is available for this agent-owned command.", "Comment" },
    })
  end

  return lines
end

---@param card CodeCompanion.Chat.UI.ActivityCard
---@return string|nil
local function summary_suffix(card)
  if card.status == "running" then
    return card.background and " [background]" or nil
  end
  return " [" .. card.status .. "]"
end

---Find the row of a card's summary line
---@param bufnr number
---@param card CodeCompanion.Chat.UI.ActivityCard
---@return number|nil
local function card_row(bufnr, card)
  if not card.mark_id then
    return nil
  end

  local position = api.nvim_buf_get_extmark_by_id(bufnr, NS, card.mark_id, {})
  return position and position[1]
end

---@param chat CodeCompanion.Chat
---@param card CodeCompanion.Chat.UI.ActivityCard
local function write_summary(chat, card)
  local line_number, icon_id = chat:add_buf_message({
    role = config.constants.LLM_ROLE,
    content = card.title,
  }, {
    status = icon_status(card.status),
    virt_text_pos = "inline",
    type = chat.MESSAGE_TYPES.TOOL_MESSAGE,
    tools = { call_id = card.id },
    kind = card.kind,
  })

  if not line_number then
    return log:debug("[Activity] Could not write the card for %q", card.id)
  end

  local row = line_number - 1
  local text = api.nvim_buf_get_lines(chat.bufnr, row, row + 1, false)[1]
  if text ~= card.title then
    for candidate = row - 1, math.max(0, row - 4), -1 do
      local candidate_text = api.nvim_buf_get_lines(chat.bufnr, candidate, candidate + 1, false)[1]
      if candidate_text == card.title then
        row = candidate
        break
      end
    end
  end

  card.line_number = row + 1
  card.icon_id = icon_id
  card.mark_id = api.nvim_buf_set_extmark(chat.bufnr, NS, row, 0, {})
end

---@param chat CodeCompanion.Chat
---@param card CodeCompanion.Chat.UI.ActivityCard
local function render(chat, card)
  local state = registry[chat.bufnr]
  if not state then
    return
  end

  if card.parent_id then
    local parent = state.cards[card.parent_id]
    if parent then
      return render(chat, parent)
    end
  end

  local row = card_row(chat.bufnr, card)
  if not row then
    return
  end

  if not card.append_only then
    local ok, updated, new_icon_id = pcall(chat.update_buf_line, chat, {
      line_number = row + 1,
      content = card.title,
      status = icon_status(card.status),
      icon_id = card.icon_id,
      priority = 120,
      virt_text_pos = "inline",
    })

    if ok and updated and new_icon_id then
      card.icon_id = new_icon_id
    end
  end

  local options = { id = card.mark_id, virt_lines = virtual_lines(card, state.cards) }
  local suffix = summary_suffix(card)
  if suffix then
    options.virt_text = { { suffix, "Comment" } }
    options.virt_text_pos = "eol"
  end

  pcall(api.nvim_buf_set_extmark, chat.bufnr, NS, row, 0, options)
end

---@param card CodeCompanion.Chat.UI.ActivityCard
---@param status string
local function set_status(card, status)
  card.status = normalise_status(status)

  if card.status == "running" then
    card.expanded = true
    card.user_toggled = false
  elseif not card.user_toggled then
    card.expanded = default_expanded(card.status)
  end
end

---Add or update an activity card
---@param chat CodeCompanion.Chat
---@param opts { id?: string, title?: string, status?: string, output?: any, parent_id?: string, kind?: string, external?: boolean, job?: vim.SystemObj, terminal_bufnr?: number, terminal_id?: string, on_stop?: fun(), on_background?: fun() }
---@return CodeCompanion.Chat.UI.ActivityCard
function M.upsert(chat, opts)
  opts = opts or {}

  local state = state_for(chat.bufnr)
  local id = opts.id
  local append_only = false

  if type(id) ~= "string" or id == "" then
    state.next_id = state.next_id + 1
    id = "__activity_" .. state.next_id
    append_only = true
    log:debug("[Activity] No stable id supplied for %q; rendering append-only", opts.title or "activity")
  end

  local card = state.cards[id]

  if not card then
    card = {
      id = id,
      title = opts.title or "Activity",
      status = normalise_status(opts.status),
      output = {},
      output_truncated = false,
      expanded = true,
      user_toggled = false,
      children = {},
      background = false,
      external = opts.external == true,
      kind = opts.kind,
      append_only = append_only,
      job = opts.job,
      terminal_bufnr = opts.terminal_bufnr,
      terminal_id = opts.terminal_id,
      on_stop = opts.on_stop,
      on_background = opts.on_background,
    }
    card.expanded = default_expanded(card.status)

    state.cards[id] = card
    table.insert(state.order, id)

    if type(opts.parent_id) == "string" and opts.parent_id ~= "" then
      local parent = state.cards[opts.parent_id]
      if parent then
        card.parent_id = opts.parent_id
        table.insert(parent.children, id)
      else
        log:debug("[Activity] Parent %q not found for %q; rendering at the top level", opts.parent_id, id)
      end
    end

    if not card.parent_id then
      write_summary(chat, card)
    end
  else
    if opts.title then
      card.title = opts.title
    end
    if opts.job then
      card.job = opts.job
    end
    if opts.terminal_bufnr then
      card.terminal_bufnr = opts.terminal_bufnr
    end
    if opts.terminal_id then
      card.terminal_id = opts.terminal_id
      if card.snapshot_bufnr then
        pcall(api.nvim_buf_delete, card.snapshot_bufnr, { force = true })
        card.snapshot_bufnr = nil
      end
    end
    if opts.on_stop then
      card.on_stop = opts.on_stop
    end
    if opts.on_background then
      card.on_background = opts.on_background
    end
    if opts.external ~= nil then
      card.external = opts.external
    end
    if opts.kind then
      card.kind = opts.kind
    end
    if opts.status then
      set_status(card, opts.status)
    end
  end

  if opts.output ~= nil then
    card.output, card.output_truncated = normalise_output(opts.output)
  end

  render(chat, card)
  return card
end

---Attach a real process handle to a card
---@param chat CodeCompanion.Chat
---@param id string
---@param job vim.SystemObj
---@return nil
function M.attach_job(chat, id, job)
  local card = M.get(chat, id)
  if not card then
    return
  end
  card.job = job
  render(chat, card)
end

---@param chat CodeCompanion.Chat
---@param id string
---@return CodeCompanion.Chat.UI.ActivityCard|nil
function M.get(chat, id)
  local state = registry[chat.bufnr]
  return state and state.cards[id] or nil
end

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.UI.ActivityCard[]
function M.cards(chat)
  local state = registry[chat.bufnr]
  if not state then
    return {}
  end
  return vim
    .iter(state.order)
    :map(function(id)
      return state.cards[id]
    end)
    :totable()
end

---Toggle a card's output
---@param chat CodeCompanion.Chat
---@param id string
---@return boolean
function M.toggle(chat, id)
  local card = M.get(chat, id)
  if not card then
    return false
  end

  card.user_toggled = true
  card.expanded = not card.expanded
  render(chat, card)
  return true
end

---Send a running local command to the background
---@param chat CodeCompanion.Chat
---@param id string
---@return boolean
function M.background(chat, id)
  local card = M.get(chat, id)
  if not card or card.external or not card.job or card.status ~= "running" or not card.on_background then
    return false
  end

  card.on_background()
  card.background = true
  render(chat, card)
  return true
end

---Stop a running local command
---@param chat CodeCompanion.Chat
---@param id string
---@return boolean
function M.stop(chat, id)
  local card = M.get(chat, id)
  if not card then
    return false
  end

  if card.on_stop then
    card.on_stop()
  elseif card.job then
    pcall(function()
      card.job:kill("sigterm")
    end)
  end

  card.job = nil
  card.background = false
  set_status(card, "cancelled")
  render(chat, card)
  return true
end

---Open a card's terminal buffer when one exists
---@param chat CodeCompanion.Chat
---@param id string
---@return boolean
function M.open_terminal(chat, id)
  local card = M.get(chat, id)
  if not card or not card.terminal_bufnr or not api.nvim_buf_is_valid(card.terminal_bufnr) then
    return false
  end

  vim.cmd("sbuffer " .. card.terminal_bufnr)
  return true
end

---Update the read-only snapshot for an agent-owned command
---@param chat CodeCompanion.Chat
---@param id string
---@param opts { command: string, output: string[], status: string }
---@return number|nil bufnr
function M.set_snapshot(chat, id, opts)
  local card = M.get(chat, id)
  if not card then
    return nil
  end
  opts = opts or {}

  local bufnr = card.snapshot_bufnr
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    bufnr = api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "markdown"
    card.snapshot_bufnr = bufnr
  end

  local lines = {
    "# Agent-owned command",
    "",
    "```",
    opts.command or card.title,
    "```",
    "",
    "CodeCompanion cannot attach to this process. The output below is what the agent reported.",
    "",
  }

  local output = normalise_output(opts.output)
  if #output == 0 then
    if opts.status == "running" or opts.status == "in_progress" then
      table.insert(lines, "The agent has not reported output yet.")
    else
      table.insert(lines, "The agent did not report any output.")
    end
  else
    vim.list_extend(lines, output)
  end

  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  return bufnr
end

---Open a card's command snapshot
---@param chat CodeCompanion.Chat
---@param id string
---@return boolean
function M.open_snapshot(chat, id)
  local card = M.get(chat, id)
  if not card or not card.snapshot_bufnr or not api.nvim_buf_is_valid(card.snapshot_bufnr) then
    return false
  end

  vim.cmd("sbuffer " .. card.snapshot_bufnr)
  return true
end

---Keep the card's final output when its terminal is released
---@param chat CodeCompanion.Chat
---@param terminal_id string
---@param output string
---@return nil
function M.detach_terminal(chat, terminal_id, output)
  local state = registry[chat.bufnr]
  if not state then
    return
  end

  for _, card in pairs(state.cards) do
    if card.terminal_id == terminal_id then
      card.terminal_id = nil
      card.terminal_bufnr = nil
      if output ~= nil then
        card.output, card.output_truncated = normalise_output(output)
      end
      render(chat, card)
    end
  end
end

---List the actions that are genuinely available for a card
---@param card CodeCompanion.Chat.UI.ActivityCard
---@param chat CodeCompanion.Chat
---@return { label: string, run: fun() }[]
function M.actions_for(card, chat)
  local actions = {}

  if #card.output > 0 or #card.children > 0 then
    table.insert(actions, {
      label = card.expanded and "Collapse output" or "Expand output",
      run = function()
        M.toggle(chat, card.id)
      end,
    })
  end

  if card.terminal_bufnr and api.nvim_buf_is_valid(card.terminal_bufnr) then
    table.insert(actions, {
      label = "Open terminal",
      run = function()
        M.open_terminal(chat, card.id)
      end,
    })
  end

  if card.snapshot_bufnr and api.nvim_buf_is_valid(card.snapshot_bufnr) then
    table.insert(actions, {
      label = "View command snapshot",
      run = function()
        M.open_snapshot(chat, card.id)
      end,
    })
  end

  if card.job and card.status == "running" and not card.external then
    if card.on_background and not card.background then
      table.insert(actions, {
        label = "Send to background",
        run = function()
          M.background(chat, card.id)
        end,
      })
    end
    table.insert(actions, {
      label = "Stop command",
      run = function()
        M.stop(chat, card.id)
      end,
    })
  end

  return actions
end

---@param state CodeCompanion.Chat.UI.ActivityState
---@param line number
---@return CodeCompanion.Chat.UI.ActivityCard|nil
local function card_at_line(state, line)
  for _, id in ipairs(state.order) do
    local card = state.cards[id]
    if card and card.line_number == line then
      return card
    end
  end
  return nil
end

---@param state CodeCompanion.Chat.UI.ActivityState
---@param card CodeCompanion.Chat.UI.ActivityCard
---@param entries CodeCompanion.Chat.UI.ActivityCard[]
---@param depth number
local function collect_children(state, card, entries, depth)
  for _, child_id in ipairs(card.children) do
    local child = state.cards[child_id]
    if child then
      child.depth = depth
      table.insert(entries, child)
      collect_children(state, child, entries, depth + 1)
    end
  end
end

---Show the actions that are genuinely available for the card under the cursor
---@param chat CodeCompanion.Chat
---@return nil
function M.actions(chat)
  local state = registry[chat.bufnr]
  if not state then
    return utils.notify("No activity cards in this chat", vim.log.levels.INFO)
  end

  local cursor = api.nvim_win_get_cursor(0)[1]
  local card = card_at_line(state, cursor)
  if not card then
    return utils.notify("No activity card under the cursor", vim.log.levels.INFO)
  end

  local entries = { card }
  collect_children(state, card, entries, 1)

  local function choose_card(on_choice)
    if #entries == 1 then
      return on_choice(card)
    end
    vim.ui.select(entries, {
      prompt = "Activity card",
      format_item = function(entry)
        return string.rep("  ", entry.depth or 0) .. entry.title .. " [" .. entry.status .. "]"
      end,
    }, function(entry)
      if entry then
        on_choice(entry)
      end
    end)
  end

  choose_card(function(entry)
    local actions = M.actions_for(entry, chat)
    if #actions == 0 then
      return utils.notify("No actions are available for this activity card", vim.log.levels.INFO)
    end

    vim.ui.select(actions, {
      prompt = "Activity: " .. entry.title,
      format_item = function(action)
        return action.label
      end,
    }, function(action)
      if action then
        action.run()
      end
    end)
  end)
end

---Remove all activity state for a buffer
---@param bufnr number
---@return nil
function M.cleanup(bufnr)
  local state = registry[bufnr]
  if state then
    for _, card in pairs(state.cards) do
      if card.snapshot_bufnr and api.nvim_buf_is_valid(card.snapshot_bufnr) then
        pcall(api.nvim_buf_delete, card.snapshot_bufnr, { force = true })
      end
    end
  end

  registry[bufnr] = nil
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
end

return M
