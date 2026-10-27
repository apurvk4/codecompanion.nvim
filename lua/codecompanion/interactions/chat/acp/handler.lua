local Activity = require("codecompanion.interactions.chat.ui.activity")
local Queue = require("codecompanion.utils.queue")
local Terminal = require("codecompanion.interactions.chat.terminal")

local async = require("codecompanion.utils.async")
local config = require("codecompanion.config")
local formatter = require("codecompanion.interactions.chat.acp.formatters")
local log = require("codecompanion.utils.log")
local markdown = require("codecompanion.utils.markdown")
local utils = require("codecompanion.utils")
local watch = require("codecompanion.interactions.shared.watch")

---@class CodeCompanion.Chat.ACPHandler
---@field chat CodeCompanion.Chat
---@field output table Standard output message from the Agent
---@field reasoning table Reasoning output from the Agent
---@field tools table<string, table> Cache of tool calls by their ID
---@field edits table<string, { path: string, line?: number }[]> Files each tool call has edited, by tool call ID
---@field _permission { queue: CodeCompanion.Queue, active: boolean, respond: function|nil } Internal state for managing permission requests
local ACPHandler = {}

---@param chat CodeCompanion.Chat
---@return CodeCompanion.Chat.ACPHandler
function ACPHandler.new(chat)
  local self = setmetatable({
    chat = chat,
    output = {},
    reasoning = {},
    tools = {},
    edits = {},
    _permission = {
      active = false,
      queue = Queue.new(),
      respond = nil,
    },
  }, { __index = ACPHandler })

  return self --[[@type CodeCompanion.Chat.ACPHandler]]
end

---Merge an incoming tool call/update into the cache
---@param existing table|nil
---@param incoming table|nil
---@return table
local function merge_tool_call(existing, incoming)
  local out = vim.deepcopy(existing or {})
  for k, v in pairs(incoming or {}) do
    if v ~= vim.NIL then
      out[k] = v
    end
  end
  return out
end

---The files a tool call update edits, alongside locations and diffs
---@param tool_call table
---@return { path: string, line?: number, added?: number, removed?: number }[]
local function touched_files(tool_call)
  local touched = {}

  local function count_changes(old_text, new_text)
    old_text = type(old_text) == "string" and old_text or ""
    new_text = type(new_text) == "string" and new_text or ""
    local diff = vim.diff(old_text, new_text, { result_type = "unified" })
    local added, removed = 0, 0
    for line in diff:gmatch("[^\n]+") do
      if line:sub(1, 1) == "+" and line:sub(1, 3) ~= "+++" then
        added = added + 1
      elseif line:sub(1, 1) == "-" and line:sub(1, 3) ~= "---" then
        removed = removed + 1
      end
    end
    return added, removed
  end

  for _, location in ipairs(tool_call.locations or {}) do
    table.insert(touched, { path = location.path, line = location.line })
  end
  for _, content in ipairs(tool_call.content or {}) do
    if content.type == "diff" then
      local added, removed = count_changes(content.oldText, content.newText)
      table.insert(touched, { path = content.path, added = added, removed = removed })
    end
  end

  return touched
end

---The tool result text the agent supplied for a tool call
---@param tool_call table
---@return string[]
local function tool_output(tool_call)
  local output = {}

  if type(tool_call.rawOutput) == "string" and tool_call.rawOutput ~= "" then
    table.insert(output, tool_call.rawOutput)
  end

  for _, content in ipairs(tool_call.content or {}) do
    if type(content) == "table" and content.type == "text" and type(content.text) == "string" then
      table.insert(output, content.text)
    end
  end

  return output
end

---The terminal a tool call content block points at
---@param tool_call table
---@return string|nil
local function terminal_id_for(tool_call)
  for _, content in ipairs(tool_call.content or {}) do
    if type(content) == "table" and content.type == "terminal" and type(content.terminalId) == "string" then
      return content.terminalId
    end
  end
end

---The command an execute tool call reports, taken from its input or its title
---@param tool_call table
---@param title string
---@return string
local function command_for(tool_call, title)
  local raw = tool_call.rawInput
  if type(raw) == "table" and type(raw.command) == "string" and raw.command ~= "" then
    local args = raw.args
    if type(args) == "table" and #args > 0 then
      return raw.command .. " " .. table.concat(args, " ")
    end
    return raw.command
  end
  if type(tool_call.title) == "string" and tool_call.title ~= "" then
    return tool_call.title
  end
  return title
end

---Submit payload to ACP, registering the request on the chat before connecting
---@param payload table The payload to send to the LLM
---@return nil
function ACPHandler:submit(payload)
  local request = {}
  request.cancel = function()
    request.cancelled = true
    if request.prompt then
      request.prompt.cancel()
    end
  end

  -- IMPORTANT: Registered before the connect below, so a second <CR> can't start a parallel submit
  self.chat.current_request = request

  -- Keep the agent's request off the main loop
  async.sync(function()
    local session_ready = self:ensure_connection() and self:ensure_session()

    -- A stop or a newer submission can replace this request while the agent boots,
    -- reporting from here would clear the handle belonging to that request
    if request.cancelled or self.chat.current_request ~= request then
      return
    end

    if not session_ready then
      self.chat.status = "error"
      return self.chat:done({ output = self.output })
    end

    request.prompt = self:create_and_send_prompt(payload)
  end)()
end

---Ensure the ACP connection is authenticated
---@return boolean
function ACPHandler:ensure_connection()
  -- If the async init already created the connection, check if it's ready
  if self.chat.acp_connection and self.chat.acp_connection:is_ready() then
    return true
  end

  if not self.chat.acp_connection then
    local adapter = self.chat.adapter --[[@as CodeCompanion.ACPAdapter]]
    self.chat.acp_connection = require("codecompanion.acp").new({
      adapter = adapter,
      chat = self.chat,
    })
  end

  local connected = self.chat.acp_connection:connect_and_authenticate()

  if not connected then
    return false
  end

  self.chat:update_metadata()
  watch.enable()
  utils.fire("ACPConnected", { bufnr = self.chat.bufnr })

  return true
end

---Ensure a session exists on the connection or create one if required
---@return boolean success
function ACPHandler:ensure_session()
  local conn = self.chat.acp_connection
  if not conn then
    return false
  end

  if conn.session_id then
    return true
  end

  if not conn:ensure_session() then
    return false
  end

  -- Map bufnr -> session_id so completion providers can look up ACP commands for this buffer
  local acp_commands = require("codecompanion.interactions.chat.acp.commands")
  acp_commands.link_buffer_to_session(self.chat.bufnr, conn.session_id)

  self.chat:update_metadata()

  require("codecompanion.interactions.chat.acp.defaults").apply(self.chat.adapter, conn)

  return true
end

---Transform ACP commands in messages from \command to /command
---@param messages table The messages to transform
---@return table The transformed messages
function ACPHandler:transform_acp_commands(messages)
  if not self.chat.acp_connection or not self.chat.acp_connection.session_id then
    return messages
  end

  -- Get available ACP commands for this session
  local acp_commands = require("codecompanion.interactions.chat.acp.commands")
  local commands = acp_commands.get_commands_for_session(self.chat.acp_connection.session_id)

  if #commands == 0 then
    return messages
  end

  -- Get trigger character
  local trigger = "\\"
  if config.interactions.chat.slash_commands.opts and config.interactions.chat.slash_commands.opts.acp then
    trigger = config.interactions.chat.slash_commands.opts.acp.trigger or "\\"
  end
  local escaped_trigger = vim.pesc(trigger)

  -- Transform messages by replacing each known command
  local transformed = vim.deepcopy(messages)
  for _, message in ipairs(transformed) do
    if message.content and type(message.content) == "string" then
      -- Replace \command with /command for each known ACP command
      for _, cmd in ipairs(commands) do
        local escaped_name = vim.pesc(cmd.name)

        -- Pattern with trailing space
        local pattern_space = escaped_trigger .. escaped_name .. "(%s)"
        message.content = message.content:gsub(pattern_space, "/" .. cmd.name .. "%1")

        -- Pattern at end of string or followed by non-word character
        local pattern_end = escaped_trigger .. escaped_name .. "([^%w])"
        message.content = message.content:gsub(pattern_end, "/" .. cmd.name .. "%1")

        -- Pattern at end of string
        local pattern_eol = escaped_trigger .. escaped_name .. "$"
        message.content = message.content:gsub(pattern_eol, "/" .. cmd.name)
      end
    end
  end

  return transformed
end

---Create and configure the prompt request with all handlers
---@param payload table
---@return table Request object
function ACPHandler:create_and_send_prompt(payload)
  -- Transform ACP commands before sending
  local transformed_payload = vim.deepcopy(payload)
  transformed_payload.messages = self:transform_acp_commands(payload.messages)

  return self.chat.acp_connection
    :session_prompt(transformed_payload.messages)
    :on_message_chunk(function(content)
      self:handle_message_chunk(content)
    end)
    :on_thought_chunk(function(content)
      self:handle_thought_chunk(content)
    end)
    :on_tool_call(function(tool_call)
      self:process_tool_call(tool_call)
    end)
    :on_tool_update(function(tool_call)
      self:process_tool_call(tool_call)
    end)
    :on_permission_request(function(request)
      self:handle_permission_request(request)
    end)
    :on_complete(function()
      self:handle_complete()
    end)
    :on_error(function(error)
      self:handle_error(error)
    end)
    :on_cancel(function()
      self:_clear_permission_queue()
    end)
    :with_options({ bufnr = self.chat.bufnr, interaction = "chat" })
    :send()
end

---Handle incoming message chunks
---@param content string
---@return nil
function ACPHandler:handle_message_chunk(content)
  table.insert(self.output, content)
  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = content },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )
end

---Handle incoming thought chunks
---@param content string
---@return nil
function ACPHandler:handle_thought_chunk(content)
  table.insert(self.reasoning, content)
  if config.display.chat.show_reasoning then
    self.chat:add_buf_message(
      { role = config.constants.LLM_ROLE, content = content },
      { type = self.chat.MESSAGE_TYPES.REASONING_MESSAGE }
    )
  end
end

---Remember the files a tool call names, as a later update can arrive without them
---@param id string
---@param tool_call table
---@return nil
function ACPHandler:track_edits(id, tool_call)
  local edits = self.edits[id] or {}

  for _, file in ipairs(touched_files(tool_call)) do
    local existing = vim.iter(edits):find(function(edit)
      return edit.path == file.path
    end)

    if existing then
      existing.line = existing.line or file.line
      existing.added = file.added or existing.added
      existing.removed = file.removed or existing.removed
    elseif type(file.path) == "string" and file.path ~= "" then
      table.insert(edits, file)
    end
  end

  self.edits[id] = edits
end

---Release a finished tool call's files, firing an event for each one it edited
---@param id string
---@param tool_call table
---@return nil
function ACPHandler:flush_edits(id, tool_call)
  if tool_call.status ~= "completed" and tool_call.status ~= "failed" then
    return
  end

  local edits = self.edits[id]
  self.edits[id] = nil

  if tool_call.status == "failed" or tool_call.kind ~= "edit" then
    return
  end

  for _, file in ipairs(edits or {}) do
    utils.fire("FileEdited", {
      path = file.path,
      tool = self.chat.adapter.name,
      line = file.line,
      added = file.added,
      removed = file.removed,
      chat_id = self.chat.id,
      chat_bufnr = self.chat.bufnr,
      tool_call_id = id,
    })
  end
end

---Write a tool call to its activity card, with a terminal or a read-only snapshot
---@param chat CodeCompanion.Chat
---@param tool_call table
---@param id string|nil
---@param title string
---@return nil
local function render_tool_call(chat, tool_call, id, title)
  local terminal_id = terminal_id_for(tool_call)
  local output = tool_output(tool_call)
  if terminal_id then
    local terminal_output = Terminal.output(terminal_id)
    if terminal_output and terminal_output.output ~= "" then
      output = terminal_output.output
    end
  end
  local status = tool_call.status or "in_progress"

  local card = Activity.upsert(chat, {
    id = id,
    title = title,
    status = status,
    output = output,
    kind = tool_call.kind,
    external = terminal_id == nil,
    terminal_id = terminal_id,
    terminal_bufnr = terminal_id and Terminal.buffer(terminal_id) or nil,
  })

  if tool_call.kind == "execute" and not terminal_id and id then
    Activity.set_snapshot(chat, card.id, {
      command = command_for(tool_call, title),
      output = output,
      status = status,
    })
  end
end

---Output tool call to the chat
---@param tool_call table
---@return nil
function ACPHandler:process_tool_call(tool_call)
  local id = tool_call.toolCallId
  if type(id) ~= "string" or id == "" then
    id = nil
  end

  local merged = merge_tool_call(id and self.tools[id] or nil, tool_call)
  tool_call = merged

  if id then
    self:track_edits(id, tool_call)

    -- Cache or cleanup
    if tool_call.status == "completed" then
      self.tools[id] = nil
    else
      self.tools[id] = merged
    end

    self:flush_edits(id, tool_call)
  end

  -- Pending tool calls are awaiting approval or streaming input, so hold them
  -- back from the buffer until the agent moves them out of the pending state
  if tool_call.status == "pending" then
    return
  end

  local ok, content = pcall(formatter.tool_message, tool_call, self.chat.adapter)
  if not ok then
    content = "[Error formatting tool output]"
  end

  render_tool_call(self.chat, tool_call, id, content)
end

---Queue a permission request and process when ready
---@param request table
---@return nil
function ACPHandler:handle_permission_request(request)
  self._permission.queue:push(request)
  self:_process_next_permission()
end

---Pop the next permission request from the queue and present it
---@return nil
function ACPHandler:_process_next_permission()
  if self._permission.active or self._permission.queue:is_empty() then
    return
  end

  self._permission.active = true
  local request = self._permission.queue:pop()

  -- Merge cached tool call data so the diff UI can activate
  local tool_call = request.tool_call
  if
    type(tool_call) == "table"
    and tool_call.toolCallId
    and (tool_call.content == nil or tool_call.content == vim.NIL)
  then
    local cached = self.tools[tool_call.toolCallId]
    if cached then
      request.tool_call = merge_tool_call(cached, tool_call)
    end
  end

  -- The original respond function is stored so that if the user cancels the request, we can respond as per the spec
  self._permission.respond = request.respond

  -- Ensure that the next item in the queue is processed after the user's response
  local send_response = request.respond
  request.respond = function(option_id, cancelled)
    if not self._permission.respond then
      return
    end
    send_response(option_id, cancelled)
    self._permission.active = false
    self._permission.respond = nil
    self:_process_next_permission()
  end

  return require("codecompanion.interactions.chat.acp.request_permission").confirm(self.chat, request)
end

---Clear any requests in the queue
---@return nil
function ACPHandler:_clear_permission_queue()
  local had_pending = self._permission.respond ~= nil or not self._permission.queue:is_empty()

  -- Cancel the currently active permission request (if any)
  if self._permission.respond then
    pcall(self._permission.respond, nil, true)
    self._permission.respond = nil
  end

  -- Cancel all queued permission requests
  while not self._permission.queue:is_empty() do
    local request = self._permission.queue:pop()
    pcall(request.respond, nil, true)
  end
  self._permission.active = false

  if had_pending then
    utils.fire("ToolApprovalFinished", { bufnr = self.chat.bufnr, choice = "cancelled" })
  end
end

---Handle the prompt response when it's complete
---@return nil
function ACPHandler:handle_complete()
  self:_clear_permission_queue()

  if not self.chat.status or self.chat.status == "" then
    self.chat.status = "success"
  end

  self.chat:done({ output = self.output, reasoning = self.reasoning, tools = {} })
end

---Handle errors
---@param error string
---@return nil
function ACPHandler:handle_error(error)
  self:_clear_permission_queue()

  self.chat.status = "error"
  log:error("[ACP::Handler] %s", error)

  self.chat:add_buf_message(
    { role = config.constants.LLM_ROLE, content = "\n" .. markdown.form_codeblock(error, { ft = "txt" }) },
    { type = self.chat.MESSAGE_TYPES.LLM_MESSAGE }
  )

  self.chat:done({ output = self.output, error = error })
end

return ACPHandler
