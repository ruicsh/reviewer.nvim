local M = {}

local comments = require("reviewer.comments")
local send = require("reviewer.send")

---@type table<number, string[]>
local keymapped = {}
---@type number|nil
local augroup = nil

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
  add_comment = "<localleader>i",
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

---@param tabpage number
function M.setup_keymaps(tabpage)
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end

  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
  end
  augroup = vim.api.nvim_create_augroup("reviewer_keymaps", { clear = true })

  for bufnr in pairs(keymapped) do
    clear_buffer(bufnr)
  end
  keymapped = {}

  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  for _, bufnr in ipairs({ orig_buf, mod_buf }) do
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      set_buffer_keymaps(bufnr)
    end
  end

  vim.api.nvim_create_autocmd("BufEnter", {
    group = augroup,
    callback = function()
      if vim.api.nvim_get_current_tabpage() ~= tabpage then
        return
      end
      -- Skip floating windows (the comment popup).
      if vim.api.nvim_win_get_config(0).relative ~= "" then
        return
      end
      if not lifecycle.get_session(tabpage) then
        return
      end
      local bufnr = vim.api.nvim_get_current_buf()
      local ob, mb = lifecycle.get_buffers(tabpage)
      if bufnr ~= ob and bufnr ~= mb then
        return
      end
      set_buffer_keymaps(bufnr)
    end,
  })
end

function M.cleanup()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  for bufnr in pairs(keymapped) do
    clear_buffer(bufnr)
  end
  keymapped = {}
end

return M
