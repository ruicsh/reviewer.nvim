local M = {}

---Format a comment's location: `file:line` on the new side, `file:~line` on
---the old side, `file:10-20` for a multi-line comment, or a bare `file` for a
---file-level comment. A comment from a scoped source adds the scope, so a
---staged comment reads `file:10 (staged)` and the agent knows to look at the
---index rather than the working tree.
---@param comment ReviewerComment
---@return string
function M.format(comment)
  local loc
  if comment.line == 0 then
    loc = comment.file
  else
    local prefix = (comment.side or "new") == "old" and "~" or ""
    if comment.end_line and comment.end_line > comment.line then
      loc = string.format("%s:%s%d-%d", comment.file, prefix, comment.line, comment.end_line)
    else
      loc = string.format("%s:%s%d", comment.file, prefix, comment.line)
    end
  end
  if comment.scope and comment.scope ~= "" then
    return string.format("%s (%s)", loc, comment.scope)
  end
  return loc
end

return M
