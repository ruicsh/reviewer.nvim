local M = {}

---Resolve the cursor to a review position through whichever source owns the
---buffer. Kept separate from `sources` so callers do not need to know that a
---buffer might not be a review surface at all.
---@param bufnr? number defaults to the current buffer
---@return ReviewerPosition|nil
function M.get(bufnr)
  local source = require("reviewer.sources").resolve(bufnr)
  if not source then
    return nil
  end
  local ok, pos = pcall(source.position, bufnr or 0)
  return ok and pos or nil
end

---Map a selection to file lines. Sources that cannot map it (a diff whose
---selection crosses sides) return nil and the caller falls back to a plain
---line range.
---@param start_row number
---@param end_row number
---@return { file: string, line: number, end_line: number|nil, side: "old"|"new", scope: string|nil }|nil
function M.range(start_row, end_row)
  local source = require("reviewer.sources").resolve()
  if not source or not source.range then
    return nil
  end
  local ok, range = pcall(source.range, start_row, end_row)
  return ok and range or nil
end

return M
