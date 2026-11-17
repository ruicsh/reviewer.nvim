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

---@param bufnr number
local function set_buffer_keymaps(bufnr)
  clear_buffer(bufnr)
  local mapped = {}

  local function set(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      nowait = true,
      desc = desc,
    })
    table.insert(mapped, lhs)
  end

  set("i", function()
    comments.add_at_cursor()
  end, "Add comment")
  set("F", function()
    comments.file_comment()
  end, "File comment")
  set("e", function()
    comments.edit_at_cursor()
  end, "Edit comment")
  set("d", function()
    comments.delete_at_cursor()
  end, "Delete comment")
  set("c", function()
    comments.list()
  end, "List comments")
  set("]n", function()
    comments.goto_next()
  end, "Next comment")
  set("[n", function()
    comments.goto_prev()
  end, "Previous comment")
  set("S", function()
    send.to_sidekick()
  end, "Send comments to sidekick")
  set("q", function()
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
