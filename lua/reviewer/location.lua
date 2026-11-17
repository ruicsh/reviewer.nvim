local M = {}

---Format a comment's location: `file:line` on the new side, `file:~line` on
---the old side, or a bare `file` for a file-level comment.
---@param comment ReviewerComment
---@return string
function M.format(comment)
  if comment.line == 0 then
    return comment.file
  end
  if (comment.side or "new") == "old" then
    return string.format("%s:~%d", comment.file, comment.line)
  end
  return string.format("%s:%d", comment.file, comment.line)
end

return M
