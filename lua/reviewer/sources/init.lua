local M = {}

---A source turns a buffer into review positions and owns the parts that differ
---between git plugins: how a cursor becomes `file:line`, how its comments are
---drawn, and how a comment is jumped to.
---
---Add another plugin by dropping a module in this directory and listing it in
---`modules`. A source must provide `matches`, `position`, `refresh`, and
---`jump`; `range` is optional and lets a multi-line selection map to file
---lines, and `repo_root` lets the store key off the right repository.
---
---Sources must not share a mechanism, only this contract. Anything that cannot
---be reduced to `{ file, line, side, scope }` is not a source: forge review
---plugins (octo, gitlab.nvim) own thread identity on the server, so routing
---them through this local store would desynchronize.
---
---@class ReviewerSource
---@field name string
---@field matches fun(bufnr: number): boolean
---@field position fun(bufnr: number): ReviewerPosition|nil
---@field range? fun(start_row: number, end_row: number): { file: string, line: number, end_line: number|nil, side: "old"|"new", scope: string|nil }|nil
---@field refresh fun(bufnr: number)
---@field row? fun(comment: ReviewerComment): number|nil buffer row showing a comment
---@field jump fun(comment: ReviewerComment): boolean returns true when handled
---@field repo_root? fun(): string|nil

---Order matters only when two sources could claim the same buffer. `codediff`
---is tab-scoped and `fugitive` is filetype-scoped, so they cannot overlap.
local modules = {
  "reviewer.sources.fugitive",
  "reviewer.sources.codediff",
}

---@type ReviewerSource[]|nil
local sources = nil

---@return ReviewerSource[]
local function all()
  if not sources then
    sources = {}
    for _, name in ipairs(modules) do
      local ok, source = pcall(require, name)
      if ok then
        table.insert(sources, source)
      end
    end
  end
  return sources
end

---Source that owns `bufnr`, or nil when the buffer is not a review surface.
---@param bufnr? number defaults to the current buffer
---@return ReviewerSource|nil
function M.resolve(bufnr)
  bufnr = bufnr or 0
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  for _, source in ipairs(all()) do
    local ok, matched = pcall(source.matches, bufnr)
    if ok and matched then
      return source
    end
  end
  return nil
end

---Jump to a comment. The current source gets the first chance, since a comment
---list opened from one review surface usually targets that surface.
---@param comment ReviewerComment
---@return boolean handled
function M.jump(comment)
  local current = M.resolve()
  if current then
    local ok, handled = pcall(current.jump, comment)
    if ok and handled then
      return true
    end
  end
  for _, source in ipairs(all()) do
    if source ~= current then
      local ok, handled = pcall(source.jump, comment)
      if ok and handled then
        return true
      end
    end
  end
  return false
end

return M
