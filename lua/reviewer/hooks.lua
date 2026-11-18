local M = {}

local marks = require("reviewer.marks")

---@type number|nil tabpage with the active codediff session
local current_tabpage = nil
---@type number|nil autocmd group for buffer events
local buf_augroup = nil
---@type table<number, boolean> tabpages whose modified pane was already focused once
local focused = {}

---Normalize a codediff path value to a plain string. codediff returns a Path
---table ({ relative, absolute }); older versions return strings.
---@param path string|table|nil
---@return string|nil
local function to_path_string(path)
  if type(path) == "table" then
    if path.absolute and path.absolute ~= "" then
      return path.absolute
    end
    if path.relative and path.relative ~= "" then
      return path.relative
    end
    return nil
  end
  if path == "" then
    return nil
  end
  return path
end

---@param path string|nil
---@return string|nil
local function normalize_path(path)
  if not path then
    return path
  end
  path = path:gsub("^%./", "")
  path = path:gsub("/+$", "")
  return path
end

---Set syntax highlighting without firing FileType autocmds that other plugins
---(e.g. markdown renderers) hook into.
---@param bufnr number|nil
---@param path string|table|nil
local function set_buffer_filetype(bufnr, path)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  path = to_path_string(path)
  if not path then
    return
  end
  local ft = vim.filetype.match({ filename = path, buf = bufnr })
  if not ft then
    return
  end
  local lang = vim.treesitter.language.get_lang(ft) or ft
  if not pcall(vim.treesitter.start, bufnr, lang) then
    vim.api.nvim_set_option_value("filetype", ft, { buf = bufnr })
  end
end

---@return table|nil
local function get_lifecycle()
  local ok, lifecycle = pcall(require, "codediff.ui.lifecycle")
  return ok and lifecycle or nil
end

---Shorten a revision for display: a hash keeps the seven characters git itself
---shows in `git log --oneline`; a ref stays whole.
---@param rev string
---@return string
local function short_rev(rev)
  if rev:match("^%x+$") and #rev > 7 then
    return rev:sub(1, 7)
  end
  return rev
end

---Scope of a codediff diff: the revision slice its panes show. The new side
---decides. `nil` (or `WORKING`) means the right pane is the working tree, which
---is what an unscoped `file:line` already names. Anything else is content only
---reachable through git, so a comment must not share its identity with the
---working tree: the index is `staged`, a conflict stage `conflict:2`, a commit
---`commit:abc1234`, and any other revision pair `rev:base..target`.
---
---Lives here because the codediff lifecycle, not the source contract, is what
---knows the revisions; the source and the mark renderer both ask this module.
---@param ctx? { git_root?: string, original_revision?: string, modified_revision?: string }
---@return string|nil
function M.scope(ctx)
  if not ctx then
    return nil
  end
  local base, target = ctx.original_revision, ctx.modified_revision
  if not target or target == "WORKING" then
    return nil
  end
  if target == ":0" then
    return "staged"
  end
  local stage = target:match("^:(%d)$")
  if stage then
    return "conflict:" .. stage
  end
  if base and base ~= "" and base ~= target then
    if base == target .. "^" then
      return "commit:" .. short_rev(target)
    end
    return string.format("rev:%s..%s", short_rev(base), short_rev(target))
  end
  return "commit:" .. short_rev(target)
end

---Scope of the session on `tabpage`.
---@param tabpage number|nil
---@return string|nil
function M.scope_for(tabpage)
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  local ctx = lifecycle.get_git_context(tabpage)
  if not ctx then
    return nil
  end

  -- A history entry diffs one commit against its parent, but the review is
  -- about the commit: name it, so the agent can `git show` a single revision
  -- instead of reconstructing a parent pair.
  local target = ctx.modified_revision
  local session = lifecycle.get_session(tabpage)
  local panel = session and session.panel
  if panel and panel.name == "history" and target and target:match("^%x+$") then
    local parents = panel.data and panel.data.parents
    local first_parent = parents and parents[target] and parents[target][1]
    -- A root commit, or a file added by the commit, has no parent and no base.
    local is_parent = (first_parent ~= nil and first_parent == ctx.original_revision)
      or ctx.original_revision == target .. "^"
      or (first_parent == nil and ctx.original_revision == nil)
    if is_parent then
      return "commit:" .. short_rev(target)
    end
  end

  return M.scope(ctx)
end

---Scope of the session on screen.
---@return string|nil
function M.current_scope()
  return M.scope_for(vim.api.nvim_get_current_tabpage())
end

---Absolute path of the file a pane buffer shows, for codediff virtual buffers too.
---@param bufnr number
---@return string|nil
local function buffer_path(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name:find("^codediff://") then
    local ok, vf = pcall(require, "codediff.core.virtual_file")
    if ok then
      local git_root, _, filepath = vf.parse_url(name)
      if git_root and filepath then
        return git_root .. "/" .. filepath
      end
    end
  end
  return name ~= "" and name or nil
end

---Apply syntax highlighting to a session's two panes. Buffers stay editable.
---@param lifecycle table
---@param tabpage number
local function prepare_buffers(lifecycle, tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local raw_orig, raw_mod = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, raw_orig)
  set_buffer_filetype(mod_buf, raw_mod)
end

---@param path string|table|nil
---@return string|nil
local function relativize(path)
  path = to_path_string(path)
  if not path then
    return nil
  end
  local lifecycle = get_lifecycle()
  local git_ctx = lifecycle and current_tabpage and lifecycle.get_git_context(current_tabpage)
  if git_ctx and git_ctx.git_root then
    -- Compare forward-slash paths: buffer_path builds them from codediff URLs,
    -- while git_root carries the platform separator (backslash on Windows).
    local abs = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
    local root = git_ctx.git_root:gsub("\\", "/")
    return normalize_path(abs:gsub("^" .. vim.pesc(root) .. "/", ""))
  end
  return normalize_path(vim.fn.fnamemodify(path, ":."))
end

---@return number|nil original buffer
---@return number|nil modified buffer
function M.get_buffers()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  return lifecycle.get_buffers(current_tabpage)
end

---@return string|nil original path
---@return string|nil modified path
function M.get_paths()
  local lifecycle = get_lifecycle()
  if not lifecycle or not current_tabpage then
    return nil, nil
  end
  local orig, mod = lifecycle.get_paths(current_tabpage)
  return relativize(orig), relativize(mod)
end

---codediff's explorer for a tabpage, if the session has one.
---@param tabpage number
---@return table|nil
function M.get_explorer(tabpage)
  local lifecycle = get_lifecycle()
  if not lifecycle then
    return nil
  end
  if lifecycle.get_explorer then
    return lifecycle.get_explorer(tabpage)
  end
  if lifecycle.get_panel then
    local panel = lifecycle.get_panel(tabpage)
    if panel and panel.name == "explorer" then
      return panel.view
    end
  end
  return nil
end

---@return string|nil file repository-relative path
---@return number|nil line
---@return "old"|"new"|nil side
function M.get_cursor_position()
  local lifecycle = get_lifecycle()
  local sess = lifecycle and current_tabpage and lifecycle.get_session(current_tabpage)
  if not sess then
    return nil, nil, nil
  end

  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_win = vim.api.nvim_get_current_win()
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_win, mod_win = lifecycle.get_windows(current_tabpage)

  -- Match by window: the lifecycle's buffer ids lag behind codediff's pane swaps.
  local file_path, side
  if current_win == mod_win then
    file_path, side = mod_path, "new"
  elseif current_win == orig_win then
    file_path, side = orig_path, "old"
  else
    return nil, nil, nil
  end

  -- Inline open leaves codediff's paths empty until a file is selected.
  local path = to_path_string(file_path) or buffer_path(vim.api.nvim_get_current_buf())
  if not path then
    return nil, nil, nil
  end
  return relativize(path), cursor[1], side
end

---@param lifecycle table
---@param tabpage number
function M._focus_modified_pane(lifecycle, tabpage)
  if vim.api.nvim_win_get_config(vim.api.nvim_get_current_win()).relative ~= "" then
    return
  end
  local sess = lifecycle.get_session(tabpage)
  if sess and sess.modified_win and vim.api.nvim_win_is_valid(sess.modified_win) then
    vim.api.nvim_set_current_win(sess.modified_win)
  end
end

---@param tabpage number
function M.on_session_created(tabpage)
  local same_session = current_tabpage == tabpage
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  prepare_buffers(lifecycle, tabpage)

  -- Rebuilding the augroup is only needed when the session changes; a retry
  -- attach on the same tabpage must not tear down and recreate it.
  if not same_session or not buf_augroup then
    if buf_augroup then
      pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    end
    buf_augroup = vim.api.nvim_create_augroup("reviewer_buf_marks", { clear = true })
    vim.api.nvim_create_autocmd("BufEnter", {
      group = buf_augroup,
      callback = function()
        if vim.api.nvim_get_current_tabpage() ~= current_tabpage then
          return
        end
        local bufnr = vim.api.nvim_get_current_buf()
        local ob, mb = lifecycle.get_buffers(current_tabpage)
        if bufnr ~= ob and bufnr ~= mb then
          return
        end
        marks.refresh(M.scope_for(current_tabpage))
      end,
    })
  end

  vim.defer_fn(function()
    marks.refresh(M.scope_for(tabpage))
  end, 100)

  -- Focus the modified pane once per tabpage; CodeDiffOpen fires on every
  -- file switch and refocusing then would steal the cursor.
  if not focused[tabpage] then
    focused[tabpage] = true
    vim.defer_fn(function()
      M._focus_modified_pane(lifecycle, tabpage)
    end, 150)
  end
end

---@param tabpage number
function M.on_file_changed(tabpage)
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  prepare_buffers(lifecycle, tabpage)

  vim.defer_fn(function()
    marks.refresh(M.scope_for(tabpage))
  end, 50)
end

function M.on_session_closed()
  if current_tabpage then
    focused[current_tabpage] = nil
  end
  current_tabpage = nil
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("reviewer.keymaps").cleanup_session()
end

return M
