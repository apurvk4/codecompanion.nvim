local edited_files = require("codecompanion.interactions.shared.edited_files")

local M = {}
local namespace = vim.api.nvim_create_namespace("CodeCompanion-ChangedFiles")

---@param chat CodeCompanion.Chat
---@return nil
function M.update(chat)
  if not vim.api.nvim_buf_is_valid(chat.bufnr) then
    return
  end

  local files = edited_files.for_chat(chat.id)
  local extmark = chat._changed_files_extmark
  if extmark then
    pcall(vim.api.nvim_buf_del_extmark, chat.bufnr, namespace, extmark)
    chat._changed_files_extmark = nil
  end
  if #files == 0 then
    return
  end

  local added, removed = 0, 0
  for _, file in ipairs(files) do
    added = added + (file.added or 0)
    removed = removed + (file.removed or 0)
  end

  local virtual_lines = {
    { { string.format(" Changed files  %d  (+%d / -%d)  ·  gF to review", #files, added, removed), "Title" } },
  }
  for _, file in ipairs(files) do
    local status = file.tool == "create_file" and "A" or "M"
    table.insert(virtual_lines, {
      { " " .. status .. " ", status == "A" and "DiffAdd" or "Comment" },
      { vim.fn.fnamemodify(file.path, ":."), "Normal" },
      { string.format("  +%d -%d", file.added or 0, file.removed or 0), "Comment" },
    })
  end

  local row = math.max(0, math.min((chat.header_line or 1) - 1, vim.api.nvim_buf_line_count(chat.bufnr) - 1))
  chat._changed_files_extmark = vim.api.nvim_buf_set_extmark(chat.bufnr, namespace, row, 0, {
    virt_lines = virtual_lines,
    virt_lines_above = true,
    virt_lines_leftcol = true,
    priority = 110,
  })
end

---@param chat CodeCompanion.Chat
---@return nil
function M.setup(chat)
  vim.api.nvim_create_autocmd("User", {
    group = chat.aug,
    pattern = "CodeCompanionFileEdited",
    callback = function(args)
      if args.data and args.data.chat_id == chat.id then
        M.update(chat)
      end
    end,
  })

  chat:add_callback("on_completed", M.update)
end

return M
