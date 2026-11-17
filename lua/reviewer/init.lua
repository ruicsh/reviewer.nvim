local M = {}

local hooks = require("reviewer.hooks")
local keymaps = require("reviewer.keymaps")
local store = require("reviewer.store")
local marks = require("reviewer.marks")
local send = require("reviewer.send")

local initialized = false

---Attach reviewer to codediff sessions.
---@param opts? { sidekick?: { tool?: string }, keys?: ReviewerKeys } `sidekick.tool` is the sidekick tool that receives sent comments; nil keeps sidekick's current tool. `keys` overrides the buffer-local keymaps.
function M.setup(opts)
  -- plugin/reviewer.lua calls setup() with no opts after the user's config has
  -- already called setup(opts); skip it so the user's config is not reset.
  if opts == nil and initialized then
    return
  end

  send.setup(opts and opts.sidekick)
  keymaps.setup(opts and opts.keys)

  if initialized then
    return
  end

  vim.api.nvim_set_hl(0, "ReviewerComment", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ReviewerRange", { link = "Visual", default = true })

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

  -- The deferred checks above can run before codediff finishes building or
  -- swapping its panes. Entering an unattached pane retries the attach.
  -- Guarded to codediff tabs so it does not schedule work for every buffer.
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    group = augroup,
    callback = function()
      local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
      if not ok or not lifecycle.get_session(vim.api.nvim_get_current_tabpage()) then
        return
      end
      vim.schedule(M._on_buf_enter)
    end,
  })

  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "CodeDiffVirtualFileLoaded",
    callback = function()
      vim.schedule(M._on_buf_enter)
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

---Attach when a session window shows a buffer that has no keymaps yet.
function M._on_buf_enter()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  if not ok then
    return
  end
  local orig_win, mod_win = lifecycle.get_windows(vim.api.nvim_get_current_tabpage())
  for _, win in ipairs({ orig_win or false, mod_win or false }) do
    if win and vim.api.nvim_win_is_valid(win) and not keymaps.is_attached(vim.api.nvim_win_get_buf(win)) then
      M._check_session()
      return
    end
  end
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
