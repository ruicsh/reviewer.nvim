local M = { name = "fugitive" }

---Signature of the last render per buffer. Re-deriving positions is cheap (one
---pass over the buffer), but rewriting extmarks on every cursor move is not, so
---the marks are only redrawn when a derived position actually changed.
---@type table<number, string>
local rendered = {}

---Fugitive's status buffer is a rendered view over git data: file entry lines
---(`M path`), section headings (`Staged (1)`), and, once expanded, the real
---unified diff of each file. That diff is plain text in the buffer, so a
---comment's file line and side can be derived from the `@@` header and the
---sigils, with no fugitive internals.
---
---Hunk expansion and collapse rewrite the buffer without firing a useful
---autocmd, so positions are re-derived from the text instead of tracked, and
---the extmarks are rebuilt whenever the derivation changes.

---@class ReviewerPosition
---@field file string repository-relative path
---@field line number 0 for a file entry line, real file line for hunk lines
---@field side "old"|"new"
---@field scope string|nil source-defined slice of the review: here the git
---  section (`staged`, `unstaged`, `untracked`). The same file and line can
---  appear in two scopes with different content, so `scope` is part of a
---  comment's identity.
---@field at_file_anchor? boolean the cursor is on the file's comment anchor:
---  line 1 in codediff, the file entry line here.

local ENTRY = "^([A-Z?]) (.*)$"
local HEADING = "^(%u%l+)%s+%(%d+%+?%)$"
local HUNK_HEADER = "^@@ %-(%d+),?%d* %+(%d+),?%d* @@"

---Walk the status buffer once. `fn(lnum, pos)` is called for every line; `pos`
---is nil for lines that are not a comment target: headings, blanks, hunk
---headers, and `\ No newline` markers.
---@param lines string[]
---@param fn fun(lnum: number, pos: ReviewerPosition|nil)
local function walk(lines, fn)
  local scope, file
  local old, new
  local in_hunk = false

  for i = 1, #lines do
    local line = lines[i]
    local status, path = line:match(ENTRY)

    if status and path ~= "" then
      -- A file entry is a comment target on its own: that is a file-level
      -- comment, stored as line 0.
      file, in_hunk = path, false
      fn(i, { file = file, line = 0, side = "new", scope = scope, at_file_anchor = true })
    else
      local heading = line:match(HEADING)
      if heading then
        scope, file, in_hunk = heading:lower(), nil, false
        fn(i, nil)
      elseif line:match(HUNK_HEADER) then
        old, new = line:match(HUNK_HEADER)
        old, new = tonumber(old), tonumber(new)
        in_hunk = true
        fn(i, nil)
      elseif in_hunk and file then
        local sigil = line:sub(1, 1)
        local pos
        if sigil == " " then
          pos = { line = new, side = "new" }
          old, new = old + 1, new + 1
        elseif sigil == "+" then
          pos = { line = new, side = "new" }
          new = new + 1
        elseif sigil == "-" then
          pos = { line = old, side = "old" }
          old = old + 1
        elseif sigil == "\\" then
          -- `\ No newline at end of file` belongs to no line on either side.
          pos = nil
        elseif sigil ~= "@" then
          -- Anything else ends the hunk: a stray indented line is not diff.
          in_hunk = false
        end
        fn(i, pos and { file = file, line = pos.line, side = pos.side, scope = scope } or nil)
      else
        fn(i, nil)
      end
    end
  end
end

---Derive the file position a status buffer line stands for.
---@param lines string[] buffer lines, 1-indexed
---@param lnum number cursor line
---@return ReviewerPosition|nil nil on a heading, blank line, or hunk header
function M.derive(lines, lnum)
  local found
  walk(lines, function(i, pos)
    if i == lnum then
      found = pos or false
    end
  end)
  return found or nil
end

---Position at the cursor of a fugitive buffer.
---@param bufnr number
---@return ReviewerPosition|nil
function M.position(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  return M.derive(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), vim.api.nvim_win_get_cursor(0)[1])
end

---Only the status buffer (`:Git`, `:Git status`) is a review surface: it is the
---one fugitive view that lists files and can expand their real diff.
---@param bufnr number
---@return boolean
function M.matches(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].filetype == "fugitive" and vim.b[bufnr].fugitive_type == "index"
end

---Repository root of a fugitive buffer.
---@param bufnr? number
---@return string|nil
function M.repo_root(bufnr)
  local ok, root = pcall(vim.fn.FugitiveWorkTree, bufnr or 0)
  if ok and root and root ~= "" then
    return root
  end
  return nil
end

---Map a visual selection to file lines. Every selected row must belong to the
---same file, scope, and side: a selection that takes in the removed and the
---added side, or a hunk header, has no single file range.
---@param start_row number first selected buffer line
---@param end_row number last selected buffer line
---@return { file: string, line: number, end_line: number|nil, side: "old"|"new", scope: string|nil }|nil
function M.range(start_row, end_row)
  local first, last = math.min(start_row, end_row), math.max(start_row, end_row)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local picked = {}
  walk(lines, function(lnum, pos)
    if lnum >= first and lnum <= last then
      picked[lnum] = pos or false
    end
  end)

  local file, scope, side
  local lo, hi
  for lnum = first, last do
    local pos = picked[lnum]
    if not pos or pos.line == 0 then
      return nil
    end
    if not file then
      file, scope, side = pos.file, pos.scope, pos.side
    elseif pos.file ~= file or pos.scope ~= scope or pos.side ~= side then
      return nil
    end
    lo = math.min(lo or pos.line, pos.line)
    hi = math.max(hi or pos.line, pos.line)
  end

  if not file then
    return nil
  end
  return { file = file, line = lo, end_line = hi, side = side, scope = scope }
end

---Comment positions in a status buffer, derived from the buffer text. A range
---that crosses a collapsed hunk yields one run per visible stretch, so a box
---never highlights lines that belong to another file.
---@param lines string[]
---@param comments ReviewerComment[]
---@return { comment: ReviewerComment, row: number, last_row: number }[] runs
---@return table<number, number> hidden line comments per entry row (0-based)
function M.positions(lines, comments)
  local function key(file, scope)
    return (scope or "") .. "\0" .. file
  end

  local index = {}
  for _, comment in ipairs(comments) do
    local k = key(comment.file, comment.scope)
    index[k] = index[k] or {}
    table.insert(index[k], comment)
  end

  local runs = {}
  local out = {}
  local drawn = {}
  -- Entry row per file, so line comments whose hunk is collapsed still show a
  -- marker on the file's line. `file_rows` is the fallback when staging moved
  -- the file to another scope: the comment stays visible rather than silently
  -- disappearing from the buffer.
  local entry_rows = {}
  local file_rows = {}

  walk(lines, function(lnum, pos)
    if not pos then
      return
    end
    local row = lnum - 1
    if pos.line == 0 then
      entry_rows[key(pos.file, pos.scope)] = row
      file_rows[pos.file] = file_rows[pos.file] or row
    end

    for _, comment in ipairs(index[key(pos.file, pos.scope)] or {}) do
      if comment.line == 0 then
        if pos.line == 0 then
          table.insert(out, { comment = comment, row = row, last_row = row })
          drawn[comment.id] = true
        end
      elseif
        (comment.side or "new") == pos.side
        and pos.line >= comment.line
        and pos.line <= (comment.end_line or comment.line)
      then
        local spans = runs[comment.id]
        if not spans then
          spans = {}
          runs[comment.id] = spans
        end
        local span = spans[#spans]
        if span and row == span.last_row + 1 then
          span.last_row = row
        else
          span = { comment = comment, row = row, last_row = row }
          table.insert(spans, span)
          table.insert(out, span)
        end
        drawn[comment.id] = true
      end
    end
  end)

  local hidden = {}
  for _, comment in ipairs(comments) do
    if comment.line > 0 and not drawn[comment.id] then
      local row = entry_rows[key(comment.file, comment.scope)] or file_rows[comment.file]
      if row then
        hidden[row] = (hidden[row] or 0) + 1
      end
    end
  end

  return out, hidden
end

---Identity of a render: the run rows plus the hidden counts. Two derivations
---with the same signature draw the same marks.
---@param runs { comment: ReviewerComment, row: number, last_row: number }[]
---@param hidden table<number, number>
---@return string
local function signature(runs, hidden)
  local parts = {}
  for _, run in ipairs(runs) do
    table.insert(parts, string.format("%s@%d-%d", run.comment.id, run.row, run.last_row))
  end
  for row, count in pairs(hidden) do
    table.insert(parts, string.format("h%d=%d", row, count))
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

---Draw the status buffer's marks.
---@param bufnr number
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local runs, hidden = M.positions(lines, require("reviewer.store").get_all())
  rendered[bufnr] = signature(runs, hidden)
  require("reviewer.marks").render_fugitive(bufnr, lines, runs, hidden)
end

---Redraw only when the derived positions changed. Hunk expansion, collapse, and
---a status rebuild all rewrite the buffer in place, so this runs on cursor
---movement and on text changes rather than on a dedicated event.
---@param bufnr number
function M.refresh_if_changed(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local runs, hidden = M.positions(lines, require("reviewer.store").get_all())
  local key = signature(runs, hidden)
  if rendered[bufnr] == key then
    return
  end
  rendered[bufnr] = key
  require("reviewer.marks").render_fugitive(bufnr, lines, runs, hidden)
end

---Row (1-based) showing a comment, exact line preferred over the file entry.
---@param lines string[]
---@param comment ReviewerComment
---@return number|nil
function M.find_row(lines, comment)
  local entry, any_entry, exact
  walk(lines, function(lnum, pos)
    if not pos or pos.file ~= comment.file then
      return
    end
    if pos.line == 0 then
      any_entry = any_entry or lnum
      if pos.scope == comment.scope then
        entry = entry or lnum
      end
    elseif
      pos.scope == comment.scope
      and comment.line > 0
      and pos.side == (comment.side or "new")
      and pos.line >= comment.line
      and pos.line <= (comment.end_line or comment.line)
    then
      exact = exact or lnum
    end
  end)
  return exact or entry or any_entry
end

---Row (1-based) in the current status buffer that shows a comment, falling
---back to the file's entry line when its hunk is collapsed.
---@param comment ReviewerComment
---@return number|nil
function M.row(comment)
  return M.find_row(vim.api.nvim_buf_get_lines(0, 0, -1, false), comment)
end

---Jump to a comment in the status buffer of the same repository.
---@param comment ReviewerComment
---@return boolean
function M.jump(comment)
  local root = require("reviewer.store").root()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and M.matches(bufnr) then
      local same_repo = not root or M.repo_root(bufnr) == root
      if same_repo then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local row = M.find_row(lines, comment)
        if row then
          local win = vim.fn.bufwinid(bufnr)
          if win ~= -1 then
            vim.api.nvim_set_current_win(win)
          else
            vim.api.nvim_win_set_buf(0, bufnr)
          end
          pcall(vim.api.nvim_win_set_cursor, 0, { row, 0 })
          local pos = M.derive(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), row)
          if pos and pos.line == 0 then
            require("reviewer.notify").notify(
              "Hunk is collapsed: expand it with `>` to see the comment line",
              vim.log.levels.INFO
            )
          end
          return true
        end
      end
    end
  end
  return false
end

---Buffers already attached. `_attach_fugitive` runs on every status rebuild, and
---`nvim_buf_attach` would stack duplicate callbacks.
---@type table<number, boolean>
local attached = {}

---Attach review keys to a status buffer and keep its marks in sync. Marks are
---driven by buffer line changes: fugitive rewrites the buffer in place for a
---rebuild, an expansion, or a collapse, and `on_lines` is the only hook that
---sees all three (the buffer stays nomodifiable, and no autocmd fires).
---@param bufnr number
function M.attach(bufnr)
  require("reviewer.keymaps").attach(bufnr)
  if attached[bufnr] then
    return
  end
  attached[bufnr] = true
  rendered[bufnr] = nil

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        M.refresh_if_changed(bufnr)
      end)
      return false
    end,
    on_detach = function()
      attached[bufnr] = nil
      rendered[bufnr] = nil
      require("reviewer.keymaps").detach(bufnr)
    end,
  })
end

return M
