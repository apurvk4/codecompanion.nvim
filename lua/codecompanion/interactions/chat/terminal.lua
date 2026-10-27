--[[
===============================================================================
    File:       codecompanion.interactions/chat/terminal.lua
-------------------------------------------------------------------------------
    Description:
      Manages terminal sessions for agent commands.

      A session owns one terminal buffer and its channel. Shell sessions keep an
      interactive shell for the user. Command sessions run one command for an
      ACP agent and track its output and exit status.

      ACP does not transport processes, so this module assumes the client and
      the agent share a machine and a filesystem.
===============================================================================
--]]

local log = require("codecompanion.utils.log")
local utils = require("codecompanion.utils")

local api = vim.api

local SPLIT_HEIGHT = 15

---@class CodeCompanion.Chat.TerminalSession
---@field id string
---@field kind "shell"|"command"
---@field bufnr number
---@field chan_id number
---@field owner? string
---@field command? string
---@field output_byte_limit? number
---@field exited boolean
---@field released boolean
---@field exit_code? number
---@field waiters fun(exit: table|nil)[]

---@type table<string, CodeCompanion.Chat.TerminalSession>
local active_sessions = {}

local next_id = 0

local M = {}

---Let <Esc><Esc> leave terminal mode without changing the shell
---@param bufnr number
---@return nil
local function set_escape_mapping(bufnr)
  vim.keymap.set("t", "<Esc><Esc>", "<C-\\><C-n>", {
    buffer = bufnr,
    desc = "Leave terminal mode",
  })
end

---@param session CodeCompanion.Chat.TerminalSession
---@param exit table|nil
---@return nil
local function resolve_waiters(session, exit)
  local waiters = session.waiters
  session.waiters = {}

  for _, callback in ipairs(waiters) do
    vim.schedule(function()
      callback(exit)
    end)
  end
end

---Track when a terminal's process ends
---@param session CodeCompanion.Chat.TerminalSession
---@return nil
local function watch_exit(session)
  api.nvim_create_autocmd("TermClose", {
    buffer = session.bufnr,
    once = true,
    callback = function()
      if session.released then
        return
      end

      session.exited = true
      session.exit_code = vim.v.event.status
      resolve_waiters(session, { exitCode = session.exit_code, signal = vim.NIL })
    end,
  })
end

---@param opts table
---@return table|nil
local function normalise_env(opts)
  local env = opts.env
  if type(env) ~= "table" then
    return nil
  end

  if env[1] == nil then
    if next(env) == nil then
      return vim.empty_dict()
    end
    return env
  end

  local map = {}
  for _, item in ipairs(env) do
    if type(item) == "table" and type(item.name) == "string" then
      map[item.name] = item.value or ""
    end
  end
  return map
end

---@param bufnr number
---@param chan_id number
---@param session table
---@return CodeCompanion.Chat.TerminalSession
local function register(bufnr, chan_id, session)
  session.bufnr = bufnr
  session.chan_id = chan_id
  session.exited = false
  session.released = false
  session.waiters = {}
  set_escape_mapping(bufnr)
  watch_exit(session)
  return session
end

---Run a command in a terminal buffer without changing the current window
---@param cmd string[]
---@param opts table
---@return number|nil bufnr
---@return number|nil chan_id
---@return string|nil err
local function open_hidden(cmd, opts)
  opts = opts or {}
  if vim.tbl_isempty(opts) then
    -- An empty Lua table reaches Vimscript as a list, which termopen rejects
    opts = vim.empty_dict()
  end

  local bufnr = api.nvim_create_buf(false, true)
  local ok, chan_id = pcall(function()
    local channel
    api.nvim_buf_call(bufnr, function()
      channel = vim.fn.termopen(cmd, opts)
    end)
    return channel
  end)

  if not ok or type(chan_id) ~= "number" or chan_id <= 0 then
    pcall(api.nvim_buf_delete, bufnr, { force = true })
    return nil, nil, tostring(chan_id)
  end

  return bufnr, chan_id
end

---Start an interactive shell in a new split
---@param term_id string
---@return CodeCompanion.Chat.TerminalSession|nil
local function create_shell(term_id)
  local ok, session = pcall(function()
    local bufnr = api.nvim_create_buf(false, true)
    vim.cmd("botright split")
    vim.cmd("resize " .. SPLIT_HEIGHT)
    api.nvim_win_set_buf(0, bufnr)

    local chan_id = vim.fn.termopen(vim.o.shell)
    if chan_id <= 0 then
      error("termopen returned " .. chan_id)
    end

    return register(bufnr, chan_id, { id = term_id, kind = "shell" })
  end)

  if not ok then
    log:error("Failed to start terminal %s: %s", term_id, session)
    return nil
  end

  active_sessions[term_id] = session
  return session
end

---Focus a window that shows the session, or split to show it
---@param session CodeCompanion.Chat.TerminalSession
---@return nil
local function focus_session(session)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == session.bufnr then
      return api.nvim_set_current_win(win)
    end
  end

  vim.cmd("botright split")
  vim.cmd("resize " .. SPLIT_HEIGHT)
  api.nvim_win_set_buf(0, session.bufnr)
end

---Find a session whose buffer still exists, forgetting one that has gone
---@param term_id string
---@return CodeCompanion.Chat.TerminalSession|nil
local function live_session(term_id)
  local session = active_sessions[term_id]
  if session and api.nvim_buf_is_valid(session.bufnr) then
    return session
  end
  if session then
    active_sessions[term_id] = nil
  end
end

---@param bufnr number
---@param limit? number
---@return string
---@return boolean truncated
local function buffer_output(bufnr, limit)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  while #lines > 0 and vim.trim(lines[#lines]) == "" do
    table.remove(lines)
  end

  local output = table.concat(lines, "\n")
  if not limit or limit <= 0 or #output <= limit then
    return output, false
  end

  -- Keep the last `limit` bytes without splitting a UTF-8 character
  local start_byte = #output - limit + 1
  start_byte = start_byte + vim.str_utf_start(output, start_byte)
  return output:sub(start_byte), true
end

---Run a command in a terminal session, creating the session when needed
---@param opts { cmd: string, term_id: string }
---@return boolean
function M.run_command(opts)
  opts = opts or {}

  if type(opts.cmd) ~= "string" or opts.cmd == "" then
    log:error("A command is required to run in a terminal")
    return false
  end
  if type(opts.term_id) ~= "string" or opts.term_id == "" then
    log:error("A terminal session ID is required")
    return false
  end

  local session = live_session(opts.term_id)
  if session and session.exited then
    active_sessions[opts.term_id] = nil
    session = nil
  end
  session = session or create_shell(opts.term_id)
  if not session then
    return false
  end

  local ok, err = pcall(function()
    focus_session(session)
    api.nvim_chan_send(session.chan_id, opts.cmd .. "\r")
    vim.cmd("normal! G")
    vim.cmd("startinsert")
  end)
  if not ok then
    log:error("Failed to run a command in terminal %s: %s", opts.term_id, err)
    return false
  end

  return true
end

---Start a command for an agent and return its terminal ID immediately
---@param opts { command: string, args?: string[], env?: table, cwd?: string, output_byte_limit?: number, owner?: string }
---@return string|nil terminal_id
---@return string|nil err
function M.create(opts)
  opts = opts or {}

  if type(opts.command) ~= "string" or opts.command == "" then
    return nil, "a command is required"
  end

  local args = opts.args
  if type(args) ~= "table" then
    args = {}
  end

  local cmd = { opts.command }
  vim.list_extend(cmd, args)

  local bufnr, chan_id, err = open_hidden(cmd, {
    cwd = opts.cwd,
    env = normalise_env(opts),
  })
  if not bufnr then
    return nil, err or "failed to start the command"
  end

  next_id = next_id + 1
  local terminal_id = "term_" .. next_id
  local session = register(bufnr, chan_id, {
    id = terminal_id,
    kind = "command",
    owner = opts.owner,
    command = table.concat(cmd, " "),
    output_byte_limit = opts.output_byte_limit,
  })
  active_sessions[terminal_id] = session

  return terminal_id
end

---The terminal buffer for a session
---@param terminal_id string
---@return number|nil
function M.buffer(terminal_id)
  local session = live_session(terminal_id)
  return session and session.bufnr or nil
end

---The output captured so far, with its exit status once the process ends
---@param terminal_id string
---@return table|nil result
---@return string|nil err
function M.output(terminal_id)
  local session = live_session(terminal_id)
  if not session then
    return nil, "unknown terminal"
  end

  local output, truncated = buffer_output(session.bufnr, session.output_byte_limit)
  local result = { output = output, truncated = truncated }
  if session.exited then
    result.exitStatus = { exitCode = session.exit_code, signal = vim.NIL }
  end
  return result
end

---Wait for a command to exit without blocking the editor
---@param terminal_id string
---@param callback fun(exit: table|nil)
---@return boolean
function M.wait_for_exit(terminal_id, callback)
  local session = live_session(terminal_id)
  if not session then
    return false
  end

  if session.exited then
    vim.schedule(function()
      callback({ exitCode = session.exit_code, signal = vim.NIL })
    end)
    return true
  end

  table.insert(session.waiters, callback)
  return true
end

---Stop a command but keep its terminal readable
---@param terminal_id string
---@return boolean
function M.kill(terminal_id)
  local session = live_session(terminal_id)
  if not session then
    return false
  end
  if session.exited then
    return true
  end

  local ok, err = pcall(vim.fn.jobstop, session.chan_id)
  if not ok then
    log:error("Failed to stop terminal %s: %s", terminal_id, err)
    return false
  end
  return true
end

---Kill a command, delete its buffer and forget the session
---@param terminal_id string
---@return boolean
function M.release(terminal_id)
  local session = live_session(terminal_id)
  if not session then
    return false
  end

  session.released = true
  resolve_waiters(session, nil)
  if not session.exited then
    pcall(vim.fn.jobstop, session.chan_id)
  end

  active_sessions[terminal_id] = nil
  pcall(api.nvim_buf_delete, session.bufnr, { force = true })
  return true
end

---Release every terminal owned by a chat
---@param owner string
---@return nil
function M.release_for_owner(owner)
  if not owner then
    return
  end

  local ids = {}
  for terminal_id, session in pairs(active_sessions) do
    if session.owner == owner then
      table.insert(ids, terminal_id)
    end
  end
  for _, terminal_id in ipairs(ids) do
    M.release(terminal_id)
  end
end

---List the sessions whose buffer still exists
---@return string[]
function M.sessions()
  local ids = {}
  for term_id, session in pairs(active_sessions) do
    if api.nvim_buf_is_valid(session.bufnr) then
      table.insert(ids, term_id)
    end
  end
  table.sort(ids)
  return ids
end

---Ask the user which terminal session to show
---@return nil
function M.switch()
  local sessions = M.sessions()
  if #sessions == 0 then
    return utils.notify("No terminal sessions are open", "WARN")
  end

  vim.ui.select(sessions, { prompt = "Terminal session" }, function(term_id)
    if not term_id then
      return
    end

    local session = active_sessions[term_id]
    if session and api.nvim_buf_is_valid(session.bufnr) then
      api.nvim_set_current_buf(session.bufnr)
    end
  end)
end

return M
