-- Run with `make test-codediff`. Needs codediff.nvim on the runtimepath;
-- skips when it is not installed.
--
-- This is the end-to-end check for the codediff source: a real :CodeDiff
-- session, real lifecycle revisions, real panel selection. The scope mapping
-- itself is covered by tests/test_reviewer.lua; here the codediff contract it
-- reads is: which revision a pane shows for a staged, an unstaged, a revision
-- pair, and a history entry.
vim.env.VSCODE_DIFF_NO_AUTO_INSTALL = "1"
vim.env.CODEDIFF_WATCHER_NO_AUTO_INSTALL = "1"

vim.opt.rtp:append(vim.fn.getcwd())

local function find_codediff()
  local candidates = {
    vim.fn.stdpath("data") .. "/lazy/codediff.nvim",
    vim.fn.expand("~/.local/share/nvim/lazy/codediff.nvim"),
  }
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 and vim.fn.filereadable(dir .. "/lua/codediff/init.lua") == 1 then
      return dir
    end
  end
  for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.filereadable(dir .. "/lua/codediff/init.lua") == 1 then
      return dir
    end
  end
  return nil
end

local codediff_dir = find_codediff()
if not codediff_dir then
  print("codediff tests: skipped (codediff.nvim not installed)")
  os.exit(0)
end

vim.opt.rtp:append(codediff_dir)
vim.cmd("runtime plugin/codediff.lua")

local lifecycle = require("codediff.ui.lifecycle")
local explorer_tree = require("codediff.ui.explorer.tree")
local history_panel = require("codediff.ui.history")
local hooks = require("reviewer.hooks")
local store = require("reviewer.store")
local keymaps = require("reviewer.keymaps")
local position = require("reviewer.position")
local marks = require("reviewer.marks")

require("codediff").setup({})
require("reviewer").setup({})

local ns = vim.api.nvim_create_namespace("reviewer")

local function eq(actual, expected, msg)
  assert(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

local function wait_for(predicate, msg)
  if not vim.wait(10000, predicate, 25) then
    error("timed out: " .. msg)
  end
end

local function short(hash)
  return #hash > 7 and hash:sub(1, 7) or hash
end

---Text of the comment box drawn at `row` (0-based), if any.
local function box_text(bufnr, row)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    if mark[2] == row and mark[4].virt_lines then
      for _, line in ipairs(mark[4].virt_lines) do
        for _, chunk in ipairs(line) do
          table.insert(out, chunk[1])
        end
      end
    end
  end
  return table.concat(out, "\n")
end

local function main()
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")

  local function git(...)
    local args = { "git", "-C", repo, ... }
    local out = vim.fn.systemlist(args)
    assert(vim.v.shell_error == 0, "git failed: " .. table.concat(args, " ") .. "\n" .. table.concat(out, "\n"))
    return out
  end
  local function write(name, lines)
    vim.fn.writefile(lines, repo .. "/" .. name)
  end

  git("init", "-q")
  git("config", "user.email", "test@example.com")
  git("config", "user.name", "test")
  write("a.txt", { "a1", "a2", "a3" })
  write("b.txt", { "b1", "b2" })
  git("add", "-A")
  git("commit", "-qm", "one")
  local rev1 = git("rev-parse", "HEAD")[1]
  write("c.txt", { "second c" })
  write("a.txt", { "a1", "second a2", "a3" })
  git("add", "-A")
  git("commit", "-qm", "two")
  local rev2 = git("rev-parse", "HEAD")[1]

  -- Index differs from HEAD at line 2; the working tree still matches the
  -- index. b.txt differs from the index, so it is unstaged.
  write("a.txt", { "a1", "index a2", "a3" })
  git("add", "a.txt")
  write("b.txt", { "b1", "work b2" })

  local function open(command)
    vim.cmd("cd " .. vim.fn.fnameescape(repo))
    vim.cmd("edit " .. vim.fn.fnameescape(repo .. "/a.txt"))
    local ok_cmd, err_cmd = pcall(vim.cmd, command)
    if not ok_cmd then
      error("command failed: " .. tostring(err_cmd) .. " / " .. vim.v.errmsg)
    end
    local tab
    if
      not vim.wait(10000, function()
        for _, candidate in ipairs(vim.api.nvim_list_tabpages()) do
          if lifecycle.get_session(candidate) then
            tab = candidate
            return true
          end
        end
        return false
      end, 25)
    then
      error("timed out: " .. command .. " session; errmsg=" .. vim.v.errmsg)
    end
    vim.api.nvim_set_current_tabpage(tab)
    return tab
  end

  local function panel_files(tab)
    local view = lifecycle.get_panel_view(tab)
    assert(view, "session has no panel view")
    local panel = lifecycle.get_panel_name(tab) == "history" and history_panel or explorer_tree
    local by_path = {}
    for _, entry in ipairs(panel.get_all_files(view.tree)) do
      by_path[entry.data.path] = entry.data
    end
    return view, by_path
  end

  local function select(view, data)
    view.on_file_select(data)
  end

  -- Explorer: a staged file's new side is the index, an unstaged one's is the
  -- working tree.
  local tab = open("CodeDiff")
  wait_for(function()
    local _, files = panel_files(tab)
    return files["a.txt"] ~= nil and files["b.txt"] ~= nil
  end, "explorer entries")
  local view, files = panel_files(tab)

  select(view, files["a.txt"])
  wait_for(function()
    local ctx = lifecycle.get_git_context(tab)
    return ctx and ctx.modified_revision == ":0"
  end, "staged revisions")
  eq(hooks.scope_for(tab), "staged", "a staged explorer file is scoped to the index")

  local _, mod_win = lifecycle.get_windows(tab)
  wait_for(function()
    return mod_win and vim.api.nvim_win_is_valid(mod_win) and keymaps.is_attached(vim.api.nvim_win_get_buf(mod_win))
  end, "reviewer attaches to the staged pane")
  vim.api.nvim_set_current_win(mod_win)
  vim.api.nvim_win_set_cursor(mod_win, { 2, 0 })
  local pos = position.get()
  eq(pos and pos.file, "a.txt", "position resolves the staged file")
  eq(pos and pos.scope, "staged", "position carries the index scope")

  local staged = store.add("a.txt", 2, "staged note", "new", nil, "staged")
  require("reviewer.sources.codediff").refresh(0)
  assert(
    box_text(vim.api.nvim_win_get_buf(mod_win), 1):find("staged note", 1, true),
    "a staged comment is drawn in the staged pane"
  )
  store.delete(staged.id)
  marks.clear_all()

  local _, files_again = panel_files(tab)
  select(view, files_again["b.txt"])
  wait_for(function()
    local ctx = lifecycle.get_git_context(tab)
    return ctx and ctx.original_revision ~= nil and ctx.modified_revision == nil
  end, "unstaged revisions")
  eq(hooks.scope_for(tab), nil, "an unstaged explorer file stays working-tree scoped")
  pcall(vim.cmd, "tabclose")

  -- A two-revision diff is scoped to the pair.
  local rev_tab = open("CodeDiff " .. rev1 .. " " .. rev2)
  wait_for(function()
    local _, rev_files = panel_files(rev_tab)
    return rev_files["a.txt"] ~= nil
  end, "revision entries")
  local rev_view, rev_files = panel_files(rev_tab)
  select(rev_view, rev_files["a.txt"])
  wait_for(function()
    local ctx = lifecycle.get_git_context(rev_tab)
    return ctx and ctx.modified_revision == rev2 and ctx.original_revision == rev1
  end, "revision pair")
  eq(hooks.scope_for(rev_tab), "rev:" .. short(rev1) .. ".." .. short(rev2), "a two-revision diff names both sides")
  pcall(vim.cmd, "tabclose")

  -- A history entry diffs the commit against its parent, but the review is
  -- about the commit itself.
  local hist_tab = open("CodeDiff history")
  wait_for(function()
    return lifecycle.get_panel_name(hist_tab) == "history"
  end, "history panel")
  local commit
  wait_for(function()
    local _, hist_files = panel_files(hist_tab)
    for _, data in pairs(hist_files) do
      if data.commit_hash and data.commit_hash ~= "" then
        commit = data
        return true
      end
    end
    return false
  end, "history file entries")
  select(lifecycle.get_panel_view(hist_tab), commit)
  wait_for(function()
    local ctx = lifecycle.get_git_context(hist_tab)
    return ctx and ctx.modified_revision == commit.commit_hash
  end, "history revisions")
  eq(hooks.scope_for(hist_tab), "commit:" .. short(commit.commit_hash), "a history entry is scoped to its commit")

  store.clear()
  marks.clear_all()
  vim.fn.delete(repo, "rf")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write("codediff tests failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
print("codediff tests: OK")
os.exit(0)
