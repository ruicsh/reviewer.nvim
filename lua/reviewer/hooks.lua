local M = {}

local marks = require("reviewer.marks")

---@type number|nil tabpage with the active codediff session
local current_tabpage = nil
---@type number|nil autocmd group for buffer events
local buf_augroup = nil
---@type table<number, boolean> tabpages whose modified pane was already focused once
local focused = {}
---@type table<number, {modifiable: boolean, readonly: boolean}>
local saved_buf_options = {}

---@param bufnr number|nil
local function make_readonly(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not saved_buf_options[bufnr] then
    saved_buf_options[bufnr] = {
      modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr }),
      readonly = vim.api.nvim_get_option_value("readonly", { buf = bufnr }),
    }
  end
  vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
  vim.api.nvim_set_option_value("readonly", true, { buf = bufnr })
end

function M.restore_buffer_options()
  for bufnr, opts in pairs(saved_buf_options) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_set_option_value("modifiable", opts.modifiable, { buf = bufnr })
      vim.api.nvim_set_option_value("readonly", opts.readonly, { buf = bufnr })
    end
  end
  saved_buf_options = {}
end

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

---Apply syntax highlighting and readonly options to a session's two panes.
---@param lifecycle table
---@param tabpage number
local function prepare_buffers(lifecycle, tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(tabpage)
  local raw_orig, raw_mod = lifecycle.get_paths(tabpage)
  set_buffer_filetype(orig_buf, raw_orig)
  set_buffer_filetype(mod_buf, raw_mod)
  make_readonly(orig_buf)
  make_readonly(mod_buf)
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
    local abs = vim.fn.fnamemodify(path, ":p")
    return normalize_path(abs:gsub("^" .. vim.pesc(git_ctx.git_root) .. "/", ""))
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
  local current_buf = vim.api.nvim_get_current_buf()
  local orig_path, mod_path = lifecycle.get_paths(current_tabpage)
  local orig_buf, mod_buf = lifecycle.get_buffers(current_tabpage)

  local file_path, side
  if current_buf == orig_buf then
    file_path, side = orig_path, "old"
  elseif current_buf == mod_buf then
    file_path, side = mod_path, "new"
  else
    return nil, nil, nil
  end

  if not file_path then
    return nil, nil, nil
  end
  return relativize(file_path), cursor[1], side
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
  current_tabpage = tabpage

  local lifecycle = get_lifecycle()
  if not lifecycle then
    return
  end

  prepare_buffers(lifecycle, tabpage)

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
      marks.refresh()
    end,
  })

  vim.defer_fn(function()
    marks.refresh()
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
    marks.refresh()
  end, 50)
end

function M.on_session_closed()
  if current_tabpage then
    focused[current_tabpage] = nil
  end
  current_tabpage = nil
  M.restore_buffer_options()
  if buf_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, buf_augroup)
    buf_augroup = nil
  end
  require("reviewer.keymaps").cleanup()
end

return M
