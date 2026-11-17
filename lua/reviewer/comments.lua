local M = {}

local store = require("reviewer.store")
local hooks = require("reviewer.hooks")
local popup = require("reviewer.popup")
local marks = require("reviewer.marks")
local location = require("reviewer.location")

---@param msg string
---@param level number
local function notify(msg, level)
  vim.notify(msg, level, { title = "reviewer.nvim" })
end

local function refresh_marks()
  vim.schedule(function()
    marks.refresh()
  end)
end

---Comment at the cursor, or the file-level comment when on line 1.
---@return table|nil
local function comment_at_cursor()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    return nil
  end
  local comment = store.get_at_line(file, line, side)
  if not comment and line == 1 then
    comment = store.get_file_comment(file)
  end
  return comment
end

function M.add_at_cursor()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  if store.get_at_line(file, line, side) then
    notify("Comment already exists at this line", vim.log.levels.WARN)
    return
  end
  if line == 1 and store.get_file_comment(file) then
    notify("File comment already exists; use F to edit it", vim.log.levels.WARN)
    return
  end

  popup.open(nil, function(text)
    if text then
      store.add(file, line, text, side)
      refresh_marks()
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

---Comment on the visual selection, stored as its first and last line.
function M.add_range()
  local file, _, side = hooks.get_cursor_position()
  if not file then
    notify("Could not determine cursor position", vim.log.levels.WARN)
    return
  end

  local start_line, end_line = M._visual_range()
  if not start_line or not end_line then
    notify("No line range selected", vim.log.levels.WARN)
    return
  end

  for line = start_line, end_line do
    if store.get_at_line(file, line, side) then
      notify("Comment already exists in this range", vim.log.levels.WARN)
      return
    end
  end

  popup.open(nil, function(text)
    if text then
      store.add(file, start_line, text, side, end_line)
      refresh_marks()
      if end_line > start_line then
        notify(string.format("Comment added on lines %d-%d", start_line, end_line), vim.log.levels.INFO)
      else
        notify("Comment added", vim.log.levels.INFO)
      end
    end
  end)
end

function M.file_comment()
  local file = hooks.get_cursor_position()
  if not file then
    notify("Could not determine file", vim.log.levels.WARN)
    return
  end

  local existing = store.get_file_comment(file)
  if existing then
    popup.open(existing.text, function(text)
      if text then
        store.update(existing.id, text)
        refresh_marks()
        notify("File comment updated", vim.log.levels.INFO)
      end
    end)
  else
    popup.open(nil, function(text)
      if text then
        store.add(file, 0, text)
        refresh_marks()
        notify("File comment added", vim.log.levels.INFO)
      end
    end)
  end
end

function M.edit_at_cursor()
  local comment = comment_at_cursor()
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  popup.open(comment.text, function(text)
    if text then
      store.update(comment.id, text)
      refresh_marks()
      notify("Comment updated", vim.log.levels.INFO)
    end
  end)
end

function M.delete_at_cursor()
  local comment = comment_at_cursor()
  if not comment then
    notify("No comment at cursor position", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, { prompt = "Delete this comment?" }, function(choice)
    if choice == "Yes" then
      store.delete(comment.id)
      refresh_marks()
      notify("Comment deleted", vim.log.levels.INFO)
    end
  end)
end

function M.goto_next()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    return
  end

  local comments = store.get_for_file(file, side)
  table.sort(comments, function(a, b)
    return a.line < b.line
  end)
  for _, comment in ipairs(comments) do
    if comment.line > line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end
  notify("No more comments in this file", vim.log.levels.INFO)
end

function M.goto_prev()
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    return
  end

  local comments = store.get_for_file(file, side)
  table.sort(comments, function(a, b)
    return a.line < b.line
  end)
  for i = #comments, 1, -1 do
    local comment = comments[i]
    if comment.line > 0 and comment.line < line then
      vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
      return
    end
  end
  notify("No previous comment in this file", vim.log.levels.INFO)
end

---@param comment ReviewerComment
function M.jump_to(comment)
  local tabpage = vim.api.nvim_get_current_tabpage()
  local target_line = comment.line == 0 and 1 or comment.line
  local explorer = hooks.get_explorer(tabpage)

  if not explorer then
    vim.defer_fn(function()
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    end, 0)
    return
  end

  local file_data
  local ok = pcall(function()
    for _, entry in ipairs(require("codediff.ui.explorer.tree").get_all_files(explorer.tree)) do
      if entry.data.path == comment.file then
        file_data = entry.data
        break
      end
    end
  end)
  if not ok or not file_data then
    notify("Not in this review's file list: " .. comment.file, vim.log.levels.WARN)
    return
  end

  explorer.on_file_select(file_data)
  vim.defer_fn(function()
    local lifecycle = require("codediff.ui.lifecycle")
    local orig_win, mod_win = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
    local win = (comment.side or "new") == "old" and orig_win or mod_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
  end, 100)
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
