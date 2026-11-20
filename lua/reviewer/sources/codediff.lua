local M = { name = "codediff" }

local hooks = require("reviewer.hooks")
local marks = require("reviewer.marks")

local notify = require("reviewer.notify").notify

---codediff sessions are tab-scoped, and its lifecycle is the only place that
---knows which buffers the current tab shows.
---@return table|nil
local function lifecycle()
  local ok, mod = pcall(require, "codediff.ui.lifecycle")
  return ok and mod or nil
end

---@param bufnr? number
---@return boolean
function M.matches(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lc = lifecycle()
  if not lc then
    return false
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  if not lc.get_session(tabpage) then
    return false
  end

  local orig_buf, mod_buf = lc.get_buffers(tabpage)
  if bufnr == orig_buf or bufnr == mod_buf then
    return true
  end
  -- The lifecycle lags behind pane swaps, so also match by window.
  local orig_win, mod_win = lc.get_windows(tabpage)
  for _, win in ipairs({ orig_win or false, mod_win or false }) do
    if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      return true
    end
  end
  return false
end

---@param _? number unused: the codediff lifecycle is window- and tab-based
---@return ReviewerPosition|nil
function M.position(_)
  local file, line, side = hooks.get_cursor_position()
  if not file or not line then
    return nil
  end
  -- In codediff the first buffer row is both file line 1 and the anchor a
  -- file-level comment hangs off, so line 1 is an anchor too.
  return { file = file, line = line, side = side or "new", scope = hooks.current_scope(), at_file_anchor = line == 1 }
end

---@param _? number unused: marks are rendered for both panes of the session
function M.refresh(_)
  -- Marks are rendered for both panes of the session, not one buffer.
  marks.refresh(hooks.current_scope())
end

---@return string|nil
function M.repo_root()
  local lc = lifecycle()
  local git_ctx = lc and lc.get_git_context(vim.api.nvim_get_current_tabpage())
  return git_ctx and git_ctx.git_root or nil
end

---Buffer row (1-based) of a comment in a pane. codediff buffers hold the file
---content, so a file line is a buffer row.
---@param comment ReviewerComment
---@return number|nil
function M.row(comment)
  return comment.line == 0 and 1 or comment.line
end

---Whether a scope names content the working tree cannot show. The index and the
---working tree are one family: an explorer selects a file and its group together,
---so a jump between them lands on the right slice. A revision is fixed per
---tabpage, so a comment from another revision cannot be drawn there.
---@param scope string|nil
---@return boolean
local function revision_scope(scope)
  return scope ~= nil and (scope:match("^commit:") or scope:match("^rev:") or scope:match("^conflict:")) ~= nil
end

---A jump can select the file, but not change which revision the tabpage shows.
---Warn when the comment's slice is not the one on screen instead of moving the
---cursor to a line that holds no comment.
---@param comment ReviewerComment
---@param has_explorer boolean
local function warn_if_unshowable(comment, has_explorer)
  local shown = hooks.current_scope()
  local want = comment.scope
  if want == shown then
    return
  end
  -- An explorer re-resolves the scope of whichever file it selects.
  if has_explorer and not revision_scope(want) and not revision_scope(shown) then
    return
  end
  notify(
    string.format("Comment is in %s; this review shows %s", want or "the working tree", shown or "the working tree"),
    vim.log.levels.WARN
  )
end

---Jump to a comment: select its file in the explorer, then move to the line.
---@param comment ReviewerComment
---@return boolean
function M.jump(comment)
  local lc = lifecycle()
  local tabpage = vim.api.nvim_get_current_tabpage()
  if not lc or not lc.get_session(tabpage) then
    return false
  end
  local target_line = comment.line == 0 and 1 or comment.line

  local explorer = hooks.get_explorer(tabpage)
  if not explorer then
    warn_if_unshowable(comment, false)
    vim.defer_fn(function()
      pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
    end, 0)
    return true
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
    return true
  end

  warn_if_unshowable(comment, true)
  explorer.on_file_select(file_data)
  vim.defer_fn(function()
    local orig_win, mod_win = lc.get_windows(vim.api.nvim_get_current_tabpage())
    local win = (comment.side or "new") == "old" and orig_win or mod_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
    end
    pcall(vim.api.nvim_win_set_cursor, 0, { target_line, 0 })
  end, 100)
  return true
end

return M
