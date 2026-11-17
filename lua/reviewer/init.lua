local M = {}

local hooks = require("reviewer.hooks")
local keymaps = require("reviewer.keymaps")
local store = require("reviewer.store")
local marks = require("reviewer.marks")

local initialized = false

---Attach reviewer to codediff sessions. Keys are fixed; opts is accepted so the
---plugin can be loaded with `opts = {}` without error.
---@param _opts? table
function M.setup(_opts)
  if initialized then
    return
  end

  vim.api.nvim_set_hl(0, "ReviewerComment", { link = "Comment", default = true })

  local augroup = vim.api.nvim_create_augroup("reviewer", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffOpen",
    callback = function()
      vim.defer_fn(M._check_session, 100)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffFileSelect",
    callback = function()
      vim.defer_fn(M._on_file_select, 100)
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = augroup,
    callback = function()
      vim.defer_fn(M._check_session, 100)
    end,
  })

  vim.api.nvim_create_autocmd("TabClosed", {
    group = augroup,
    callback = function()
      hooks.on_session_closed()
    end,
  })

  initialized = true
end

function M._check_session()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  if not lifecycle.get_session(tabpage) then
    return
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  store.set_repo(git_ctx and git_ctx.git_root)
  store.load()
  hooks.on_session_created(tabpage)
  keymaps.setup_keymaps(tabpage)
end

function M._on_file_select()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local tabpage = vim.api.nvim_get_current_tabpage()
  if not lifecycle.get_session(tabpage) then
    return
  end
  local git_ctx = lifecycle.get_git_context(tabpage)
  store.set_repo(git_ctx and git_ctx.git_root)
  store.load()
  hooks.on_file_changed(tabpage)
  keymaps.setup_keymaps(tabpage)
end

---Close the review: drop every comment for this branch and close the tab.
function M.close()
  store.clear()
  marks.clear_all()
  hooks.on_session_closed()
  pcall(vim.cmd, "tabclose")
end

---@return number
function M.count()
  return store.count()
end

return M
