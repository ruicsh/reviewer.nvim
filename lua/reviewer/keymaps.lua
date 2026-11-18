local M = {}

local comments = require("reviewer.comments")
local send = require("reviewer.send")

---@type table<number, string[]>
local keymapped = {}

---Buffers mapped by the last `setup_keymaps` call; the codediff session owns
---only these, so closing or switching it never touches another source's buffer.
---@type number[]
local session_buffers = {}

---@param bufnr number
local function clear_buffer(bufnr)
  local keys = keymapped[bufnr]
  if keys and vim.api.nvim_buf_is_valid(bufnr) then
    for _, lhs in ipairs(keys) do
      for _, mode in ipairs({ "n", "x" }) do
        pcall(vim.keymap.del, mode, lhs, { buffer = bufnr })
      end
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
  ---@param mode? string|string[] defaults to normal mode
  local function set(key, rhs, desc, mode)
    local lhs = config[key]
    if not lhs or lhs == "" then
      return
    end
    vim.keymap.set(mode or "n", lhs, rhs, {
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
  -- In visual mode the same key comments on the selected lines.
  set("add_comment", function()
    comments.add_range()
  end, "Add comment on range", "x")
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

---Attach the review keys to a single buffer. Sources that own one buffer (a
---fugitive status window) use this instead of the codediff pane scan.
---@param bufnr number
function M.attach(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    set_buffer_keymaps(bufnr)
  end
end

---Remove the review keys from one buffer.
---@param bufnr number
function M.detach(bufnr)
  clear_buffer(bufnr)
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

  -- Only the buffers this function mapped belong to the session. Clearing every
  -- attached buffer would drop the keys of another source's buffer, e.g. a
  -- fugitive status buffer in another tab.
  for _, bufnr in ipairs(session_buffers) do
    clear_buffer(bufnr)
  end
  session_buffers = {}

  -- Inline layout shows only the modified buffer, and the lifecycle can lag
  -- behind the windows, so map whatever the session windows display too.
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local bufs = {}
  if orig_buf then
    table.insert(bufs, orig_buf)
  end
  if mod_buf then
    table.insert(bufs, mod_buf)
  end
  local orig_win, mod_win = lifecycle.get_windows(tabpage)
  for _, win in ipairs({ orig_win or false, mod_win or false }) do
    if win and vim.api.nvim_win_is_valid(win) then
      table.insert(bufs, vim.api.nvim_win_get_buf(win))
    end
  end
  for _, bufnr in ipairs(bufs) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not keymapped[bufnr] then
      set_buffer_keymaps(bufnr)
      table.insert(session_buffers, bufnr)
    end
  end
end

---Drop the keys of the closed codediff session, leaving other sources attached.
function M.cleanup_session()
  for _, bufnr in ipairs(session_buffers) do
    clear_buffer(bufnr)
  end
  session_buffers = {}
end

function M.cleanup()
  for bufnr in pairs(keymapped) do
    clear_buffer(bufnr)
  end
  keymapped = {}
  session_buffers = {}
end

return M
