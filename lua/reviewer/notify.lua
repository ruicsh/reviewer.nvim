local M = {}

---@type boolean
local silent = false

---Silence reviewer's informational and warning messages. Errors always surface:
---a failed send or a missing dependency must not fail quietly.
---@param o? { silent?: boolean }
function M.setup(o)
  silent = o ~= nil and o.silent == true
end

---Report through `vim.notify` unless the user silenced the noise.
---@param msg string
---@param level number
function M.notify(msg, level)
  if silent and level < vim.log.levels.ERROR then
    return
  end
  vim.notify(msg, level, { title = "reviewer.nvim" })
end

return M
