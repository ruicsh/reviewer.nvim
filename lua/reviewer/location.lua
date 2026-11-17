local M = {}

---Format a comment's location: `file:line` on the new side, `file:~line` on
---the old side, `file:10-20` for a multi-line comment, or a bare `file` for a
---file-level comment.
---@param comment ReviewerComment
---@return string
function M.format(comment)
  if comment.line == 0 then
    return comment.file
  end
  local prefix = (comment.side or "new") == "old" and "~" or ""
  if comment.end_line and comment.end_line > comment.line then
    return string.format("%s:%s%d-%d", comment.file, prefix, comment.line, comment.end_line)
  end
  return string.format("%s:%s%d", comment.file, prefix, comment.line)
end

return M
