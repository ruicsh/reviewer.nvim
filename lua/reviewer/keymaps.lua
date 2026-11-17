local M = {}

local comments = require("reviewer.comments")
local send = require("reviewer.send")

---@type table<number, string[]>
local keymapped = {}

---@param bufnr number
local function clear_buffer(bufnr)
  local keys = keymapped[bufnr]
  if keys and vim.api.nvim_buf_is_valid(bufnr) then
    for _, lhs in ipairs(keys) do
      pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
    end
  end
  keymapped[bufnr] = nil
end

---@class ReviewerKeys
---@field add_comment string|false Keymap for adding a comment at the cursor; `false` disables it
---@field file_comment string|false Keymap for adding/editing a file-level comment
---@field edit_comment string|false Keymap for editing the comment at the cursor
---@field delete_comment string|false Keymap for deleting the comment at the cursor
---@field list_comments string|false Keymap for listing comments
---@field next_comment string|false Keymap for the next comment
---@field prev_comment string|false Keymap for the previous comment
---@field send_comments string|false Keymap for sending comments to sidekick
---@field close_review string|false Keymap for closing the review

---@type ReviewerKeys
local defaults = {
  add_comment = "<localleader>a",
  file_comment = "<localleader>F",
  edit_comment = "<localleader>e",
  delete_comment = "<localleader>d",
  list_comments = "<localleader>c",
  next_comment = "]n",
  prev_comment = "[n",
  send_comments = "<localleader>S",
  close_review = "<localleader>q",
}

---@type ReviewerKeys
local config = vim.deepcopy(defaults)

---Override the buffer-local keymaps. Omitted keys keep their default; `false`
---disables a keymap.
---@param opts? ReviewerKeys
function M.setup(opts)
  config = vim.tbl_extend("force", vim.deepcopy(defaults), opts or {})
end

---@param bufnr number
local function set_buffer_keymaps(bufnr)
  clear_buffer(bufnr)
  local mapped = {}

  ---@param key string config field
  ---@param rhs function
  ---@param desc string
  local function set(key, rhs, desc)
    local lhs = config[key]
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set("n", lhs, rhs, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
      desc = desc,
    })
    table.insert(mapped, lhs)
  end

  set("add_comment", function()
    comments.add_at_cursor()
  end, "Add comment")
  set("file_comment", function()
    comments.file_comment()
  end, "File comment")
  set("edit_comment", function()
    comments.edit_at_cursor()
  end, "Edit comment")
  set("delete_comment", function()
    comments.delete_at_cursor()
  end, "Delete comment")
  set("list_comments", function()
    comments.list()
  end, "List comments")
  set("next_comment", function()
    comments.goto_next()
  end, "Next comment")
  set("prev_comment", function()
    comments.goto_prev()
  end, "Previous comment")
  set("send_comments", function()
    send.to_sidekick()
  end, "Send comments to sidekick")
  set("close_review", function()
    require("reviewer").close()
  end, "Close review")

  keymapped[bufnr] = mapped
end

---@param bufnr number
---@return boolean
function M.is_attached(bufnr)
  return keymapped[bufnr] ~= nil
end

-- Map both panes of a session. codediff replaces pane buffers on file switch,
-- so callers re-run this whenever a new pane buffer shows up.
---@param tabpage number
function M.setup_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  for bufnr in pairs(keymapped) do
    clear_buffer(bufnr)
  end
  keymapped = {}

  -- Inline layout shows only the modified buffer, and the lifecycle can lag
  -- behind the windows, so map whatever the session windows display too.
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local bufs = { orig_buf, mod_buf }
  local orig_win, mod_win = lifecycle.get_windows(tabpage)
  for _, win in ipairs({ orig_win or false, mod_win or false }) do
    if win and vim.api.nvim_win_is_valid(win) then
      table.insert(bufs, vim.api.nvim_win_get_buf(win))
    end
  end
  for _, bufnr in ipairs(bufs) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not keymapped[bufnr] then
      set_buffer_keymaps(bufnr)
    end
  end
end

function M.cleanup()
  for bufnr in pairs(keymapped) do
    clear_buffer(bufnr)
  end
  keymapped = {}
end

return M
