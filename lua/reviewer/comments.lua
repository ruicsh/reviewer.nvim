local M = {}

local store = require("reviewer.store")
local position = require("reviewer.position")
local sources = require("reviewer.sources")
local popup = require("reviewer.popup")
local location = require("reviewer.location")

---@param msg string
---@param level number
local function notify(msg, level)
  vim.notify(msg, level, { title = "reviewer.nvim" })
end

---Refresh the marks of the source the comment was created in. The popup closes
---before the callback runs, so resolve the source and its buffer up front.
---@param source ReviewerSource|nil
---@param bufnr number
local function refresh_marks(source, bufnr)
  vim.schedule(function()
    if source then
      source.refresh(bufnr)
    end
  end)
end

---Comment at the cursor, or the file-level comment when the cursor is on the
---file's anchor: line 1 in codediff, the file entry in a fugitive buffer.
---@return table|nil
local function comment_at_cursor()
  local pos = position.get()
  if not pos then
    return nil
  end
  local comment = store.get_at_line(pos.file, pos.line, pos.side, pos.scope)
  if not comment and pos.at_file_anchor then
    comment = store.get_file_comment(pos.file, pos.scope)
  end
  return comment
end

function M.add_at_cursor()
  local source = sources.resolve()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = position.get()
  if not pos then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  if pos.line > 0 and store.get_at_line(pos.file, pos.line, pos.side, pos.scope) then
    notify("Comment already exists at this line", vim.log.levels.WARN)
    return
  end
  if pos.at_file_anchor and store.get_file_comment(pos.file, pos.scope) then
    notify("File comment already exists; use F to edit it", vim.log.levels.WARN)
    return
  end

  popup.open(nil, function(text)
    if text then
      store.add(pos.file, pos.line, text, pos.side, nil, pos.scope)
      refresh_marks(source, bufnr)
      notify("Comment added", vim.log.levels.INFO)
    end
  end)
end

---First and last line of the visual selection. A Lua mapping in visual mode
---runs before `'<`/`'>` are set, so read the selection marks instead.
---@return number|nil start_line
---@return number|nil end_line
function M._visual_range()
  if vim.fn.mode():find("^[vV\22]") then
    local anchor, cursor = vim.fn.line("v"), vim.fn.line(".")
    return math.min(anchor, cursor), math.max(anchor, cursor)
  end
  local start_line = vim.api.nvim_buf_get_mark(0, "<")[1]
  local end_line = vim.api.nvim_buf_get_mark(0, ">")[1]
  if start_line == 0 or end_line == 0 then
    return nil, nil
  end
  return math.min(start_line, end_line), math.max(start_line, end_line)
end

---Comment on the visual selection, stored as its first and last line. A source
---that can map the selection to file lines (a fugitive hunk) reports them, so
---buffer rows never leak into the store.
function M.add_range()
  local source = sources.resolve()
  local bufnr = vim.api.nvim_get_current_buf()

  local start_row, end_row = M._visual_range()
  if not start_row or not end_row then
    notify("No line range selected", vim.log.levels.WARN)
    return
  end

  local file, line, last, side, scope
  local resolved = position.range(start_row, end_row)
  if resolved then
    file, line, last, side, scope = resolved.file, resolved.line, resolved.end_line, resolved.side, resolved.scope
  elseif source and source.range then
    -- The source knows how to map selections and refused this one: a selection
    -- spanning both sides of a diff has no single file range, and buffer rows
    -- would be stored as file lines if we fell back here.
    notify("Selection does not map to one file range", vim.log.levels.WARN)
    return
  else
    local pos = position.get()
    if not pos then
      notify("Could not determine cursor position", vim.log.levels.WARN)
      return
    end
    file, line, last, side, scope = pos.file, start_row, end_row, pos.side, pos.scope
  end

  for lnum = line, last do
    if store.get_at_line(file, lnum, side, scope) then
      notify("Comment already exists in this range", vim.log.levels.WARN)
      return
    end
  end

  popup.open(nil, function(text)
    if text then
      store.add(file, line, text, side, last, scope)
      refresh_marks(source, bufnr)
      if last > line then
        notify(string.format("Comment added on lines %d-%d", line, last), vim.log.levels.INFO)
      else
        notify("Comment added", vim.log.levels.INFO)
      end
    end
  end)
end

function M.file_comment()
  local source = sources.resolve()
  local bufnr = vim.api.nvim_get_current_buf()
  local pos = position.get()
  if not pos then
    notify("Could not determine file", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(pos.file, pos.scope)
  if existing then
    popup.open(existing.text, function(text)
      if text then
        store.update(existing.id, text)
        refresh_marks(source, bufnr)
        notify("File comment updated", vim.log.levels.INFO)
      end
    end)
  else
    popup.open(nil, function(text)
      if text then
        store.add(pos.file, 0, text, nil, nil, pos.scope)
        refresh_marks(source, bufnr)
        notify("File comment added", vim.log.levels.INFO)
      end
    end)
  end
end

function M.edit_at_cursor()
  local source = sources.resolve()
  local bufnr = vim.api.nvim_get_current_buf()
  local comment = comment_at_cursor()
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  popup.open(comment.text, function(text)
    if text then
      store.update(comment.id, text)
      refresh_marks(source, bufnr)
      notify("Comment updated", vim.log.levels.INFO)
    end
  end)
end

function M.delete_at_cursor()
  local source = sources.resolve()
  local bufnr = vim.api.nvim_get_current_buf()
  local comment = comment_at_cursor()
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
    if choice == "Yes" then
      store.delete(comment.id)
      refresh_marks(source, bufnr)
      notify("Comment deleted", vim.log.levels.INFO)
    end
  end)
end

function M.goto_next()
  local source = sources.resolve()
  local pos = position.get()
  if not pos then
    return
  end

  local comments = store.get_for_file(pos.file, pos.side, pos.scope)
  table.sort(comments, function(a, b)
    return a.line < b.line
  end)
  for _, comment in ipairs(comments) do
    if comment.line > pos.line then
      local row = source and source.row and source.row(comment) or comment.line
      if row then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
      end
      return
    end
  end
  notify("No more comments in this file", vim.log.levels.INFO)
end

function M.goto_prev()
  local source = sources.resolve()
  local pos = position.get()
  if not pos then
    return
  end

  local comments = store.get_for_file(pos.file, pos.side, pos.scope)
  table.sort(comments, function(a, b)
    return a.line < b.line
  end)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line > 0 and comment.line < pos.line then
      local row = source and source.row and source.row(comment) or comment.line
      if row then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
      end
      return
    end
  end
  notify("No previous comment in this file", vim.log.levels.INFO)
end

---@param comment ReviewerComment
function M.jump_to(comment)
  if not sources.jump(comment) then
    notify("Could not find a review buffer for " .. comment.file, vim.log.levels.WARN)
  end
end

function M.list()
  local all = store.get_all()
  if #all == 0 then
    notify("No comments yet", vim.log.levels.INFO)
    return
  end

  local items = {}
  for _, comment in ipairs(all) do
    table.insert(items, {
      display = string.format("%s - %s", location.format(comment), comment.text),
      comment = comment,
    })
  end

  vim.ui.select(items, {
    prompt = "Comments:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if choice then
      M.jump_to(choice.comment)
    end
  end)
end

return M
