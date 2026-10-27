local utils = require("codecompanion.utils")

---@class CodeCompanion.EditedFile
---@field path string The absolute path of the edited file
---@field tool string What made the edit (e.g. "edit_file", "create_file", "claude_code")
---@field line? number The first line the edit touched, when known
---@field bufnr? number The buffer the edit was made in, when known

local store = {} ---@type CodeCompanion.EditedFile[]
local positions = {} ---@type table<string, number> Lookup of path to position in the store
local chat_edits = {} ---@type table<number, table<string, table<string, CodeCompanion.EditedFile>>>

local M = {}

---Record an edited file, refreshing its entry if it has been edited before
---@param edit CodeCompanion.EditedFile
---@return nil
local function record(edit)
  if not edit.path or edit.path == "" then
    return
  end

  local position = positions[edit.path]
  if position then
    store[position] = vim.tbl_extend("force", store[position], edit)
    return
  end

  table.insert(store, edit)
  positions[edit.path] = #store
end

---Return the files the LLM has edited, in the order they were first edited
---@return CodeCompanion.EditedFile[]
function M.all()
  return store
end

---Return the files edited by one chat with aggregated line counts
---@param chat_id number
---@return CodeCompanion.EditedFile[]
function M.for_chat(chat_id)
  local files = {}
  for _, calls in pairs(chat_edits[chat_id] or {}) do
    local total = { added = 0, removed = 0 }
    local sample
    for _, edit in pairs(calls) do
      sample = sample or edit
      total.added = total.added + (edit.added or 0)
      total.removed = total.removed + (edit.removed or 0)
    end
    if sample then
      table.insert(files, vim.tbl_extend("force", vim.deepcopy(sample), total))
    end
  end
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

---Open the edited files in the quickfix list
---@return nil
function M.to_quickfix()
  if #store == 0 then
    return utils.notify("No files have been edited this session", vim.log.levels.WARN)
  end

  local items = {}
  for _, edit in ipairs(store) do
    table.insert(items, {
      filename = edit.path,
      lnum = edit.line or 1,
      text = (edit.tool == "create_file" and "created" or "edited") .. " by " .. edit.tool,
    })
  end

  -- A new list is pushed onto the stack, so :colder restores the user's own list
  vim.fn.setqflist({}, " ", { title = "Files edited by the LLM", items = items })
  vim.cmd.copen()
end

---Track the files an LLM edits for the life of the Neovim instance
---@return nil
function M.setup()
  vim.api.nvim_create_autocmd("User", {
    group = vim.api.nvim_create_augroup("codecompanion.edited_files", { clear = true }),
    pattern = "CodeCompanionFileEdited",
    desc = "Track the files that an LLM edits or creates",
    callback = function(args)
      local edit = args.data
      record(edit)
      if edit.chat_id and edit.tool_call_id then
        chat_edits[edit.chat_id] = chat_edits[edit.chat_id] or {}
        chat_edits[edit.chat_id][edit.path] = chat_edits[edit.chat_id][edit.path] or {}
        chat_edits[edit.chat_id][edit.path][edit.tool_call_id] = vim.deepcopy(edit)
      end
    end,
  })
end

return M
