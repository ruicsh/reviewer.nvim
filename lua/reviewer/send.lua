local M = {}

local store = require("reviewer.store")
local marks = require("reviewer.marks")
local location = require("reviewer.location")

---@param msg string
---@param level number
local function notify(msg, level)
  vim.notify(msg, level, { title = "reviewer.nvim" })
end

---Markdown list of every comment, one `file:line - text` per line. A `~`
---before the line number marks the old (left) side of the diff.
---@return string|nil nil when there are no comments
function M.generate_markdown()
  local all = store.get_all()
  if #all == 0 then
    return nil
  end

  local lines = {
    "Code review comments on the current diff (`file:line`, `~` = old side).",
    "",
  }
  for i, comment in ipairs(all) do
    table.insert(lines, string.format("%d. `%s` - %s", i, location.format(comment), (comment.text:gsub("\n", " "))))
  end
  return table.concat(lines, "\n")
end

---Send every comment to sidekick.nvim, then remove them all.
function M.to_sidekick()
  local ok, sidekick = pcall(require, "sidekick.cli")
  if not ok then
    notify("sidekick.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local count = store.count()
  if count == 0 then
    notify("No comments to send", vim.log.levels.WARN)
    return
  end

  local markdown = M.generate_markdown()
  local sent, err = pcall(sidekick.send, { msg = markdown })
  if not sent then
    notify("Failed to send to sidekick: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  store.clear()
  marks.clear_all()
  notify(string.format("Sent %d comment(s) to sidekick", count), vim.log.levels.INFO)
end

return M
