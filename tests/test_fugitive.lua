-- Run with `make test-fugitive`. Needs vim-fugitive on the runtimepath; skips
-- when it is not installed.
--
-- This is the end-to-end check for the fugitive source: real status buffer,
-- real `@@` hunks, real expansion and collapse. The pure derivation is covered
-- by tests/test_reviewer.lua; here the buffer mechanics are.
vim.opt.rtp:append(vim.fn.getcwd())

local function find_fugitive()
  local candidates = {
    vim.fn.stdpath("data") .. "/lazy/vim-fugitive",
    vim.fn.expand("~/.local/share/nvim/lazy/vim-fugitive"),
  }
  for _, dir in ipairs(candidates) do
    if vim.fn.isdirectory(dir) == 1 and vim.fn.filereadable(dir .. "/plugin/fugitive.vim") == 1 then
      return dir
    end
  end
  for _, dir in ipairs(vim.api.nvim_list_runtime_paths()) do
    if vim.fn.filereadable(dir .. "/plugin/fugitive.vim") == 1 then
      return dir
    end
  end
  return nil
end

local function eq(actual, expected, msg)
  assert(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

---Line containing `text`, optionally after `after` (1-based).
local function find_line(lines, text, after)
  for i = (after or 0) + 1, #lines do
    if lines[i] == text then
      return i
    end
  end
end

---Extmarks of the reviewer namespace at `row`.
local function marks_at(bufnr, row)
  local ns = vim.api.nvim_create_namespace("reviewer")
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
    if mark[2] == row then
      table.insert(out, mark[4])
    end
  end
  return out
end

local function has_box(bufnr, row)
  for _, details in ipairs(marks_at(bufnr, row)) do
    if details.virt_lines then
      return true
    end
  end
  return false
end

local function has_sign(bufnr, row, text)
  for _, details in ipairs(marks_at(bufnr, row)) do
    -- Neovim pads sign_text to the sign column width.
    if details.sign_text and details.sign_text:gsub("%s+$", "") == text then
      return true
    end
  end
  return false
end

local function main()
  local fugitive_dir = find_fugitive()
  if not fugitive_dir then
    print("fugitive tests: SKIP (vim-fugitive not found)")
    return
  end
  vim.opt.rtp:append(fugitive_dir)
  vim.cmd("runtime plugin/fugitive.vim")

  -- A repo with one staged change, one unstaged change, and an untracked file.
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo .. "/src", "p")
  local function git(...)
    local args = { "git", "-C", repo, ... }
    local out = vim.fn.systemlist(args)
    assert(vim.v.shell_error == 0, "git failed: " .. table.concat(args, " "):gsub("\n", " "))
    return out
  end
  git("init", "-q")
  git("config", "user.email", "test@example.com")
  git("config", "user.name", "test")
  vim.fn.writefile({ "a", "b", "c" }, repo .. "/src/a.lua")
  git("add", ".")
  git("commit", "-qm", "init")

  vim.fn.writefile({ "a", "B2", "c", "d" }, repo .. "/src/a.lua")
  vim.fn.writefile({ "new" }, repo .. "/src/untracked.lua")
  git("add", "src/a.lua")
  vim.fn.writefile({ "a", "B2", "c", "d", "e" }, repo .. "/src/a.lua")
  vim.fn.chdir(repo)

  require("reviewer").setup({})
  vim.cmd("Git")
  vim.wait(1000, function()
    return vim.bo.filetype == "fugitive"
  end)
  eq(vim.bo.filetype, "fugitive", "status buffer opened")

  local bufnr = vim.api.nvim_get_current_buf()
  -- The FileType handler attaches asynchronously; wait for the keys rather than
  -- for the filetype.
  vim.wait(1000, function()
    return require("reviewer.keymaps").is_attached(bufnr)
  end)
  local function lines()
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  -- Sections and entries are what the walker expects.
  assert(find_line(lines(), "Staged (1)"), "staged section")
  assert(find_line(lines(), "M src/a.lua"), "staged entry")
  assert(find_line(lines(), "? src/untracked.lua"), "untracked entry")

  -- Keys are attached to the status buffer.
  local keys = {}
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    keys[map.lhs] = true
  end
  assert(keys[(vim.g.maplocalleader or "\\") .. "a"], "add_comment key attached")
  assert(keys["]n"], "next_comment key attached")

  -- Expand the staged hunk: the real unified diff is now in the buffer.
  local entry = find_line(lines(), "M src/a.lua", find_line(lines(), "Staged (1)"))
  vim.api.nvim_win_set_cursor(0, { entry, 0 })
  vim.cmd("normal >")
  vim.wait(500, function()
    return find_line(lines(), "@@ -1,3 +1,4 @@") ~= nil
  end)
  local added = find_line(lines(), "+B2")
  assert(added, "hunk expanded")

  -- The cursor on `+B2` maps to file line 2 on the new side, in the staged scope.
  vim.api.nvim_win_set_cursor(0, { added, 0 })
  local pos = require("reviewer.position").get()
  eq(pos.file, "src/a.lua", "file from the status buffer")
  eq(pos.line, 2, "file line from the hunk header")
  eq(pos.side, "new", "new side from the added line")
  eq(pos.scope, "staged", "scope from the section heading")

  -- A stored comment renders on the derived row.
  local store = require("reviewer.store")
  local fugitive = require("reviewer.sources.fugitive")
  store.add("src/a.lua", 2, "check this line", "new", nil, "staged")
  fugitive.refresh(bufnr)
  eq(has_box(bufnr, added - 1), true, "box on the added line")

  -- Collapsing the hunk keeps the comment visible as a count on the entry line.
  local collapsed_entry = find_line(lines(), "M src/a.lua", find_line(lines(), "Staged (1)"))
  vim.api.nvim_win_set_cursor(0, { collapsed_entry, 0 })
  vim.cmd("normal =")
  -- The refresh is scheduled from the buffer's on_lines hook, so wait for the
  -- mark, not just for the text.
  vim.wait(1000, function()
    return find_line(lines(), "+B2") == nil and has_sign(bufnr, collapsed_entry - 1, "1")
  end)
  eq(find_line(lines(), "+B2"), nil, "hunk collapsed")
  eq(has_box(bufnr, collapsed_entry - 1), false, "box gone with the hunk")
  eq(has_sign(bufnr, collapsed_entry - 1, "1"), true, "collapsed comment counted on the entry")

  -- Expanding again brings the box back on the same derived row.
  vim.api.nvim_win_set_cursor(0, { collapsed_entry, 0 })
  vim.cmd("normal =")
  vim.wait(1000, function()
    local line = find_line(lines(), "+B2")
    return line ~= nil and has_box(bufnr, line - 1)
  end)
  eq(has_box(bufnr, find_line(lines(), "+B2") - 1), true, "box back after expanding")

  -- A rebuild keeps the marks too: positions are re-derived, not tracked.
  vim.cmd("Git!")
  vim.wait(1000, function()
    local line = find_line(lines(), "+B2")
    return line ~= nil and has_box(bufnr, line - 1)
  end)
  eq(has_box(bufnr, find_line(lines(), "+B2") - 1), true, "box survives a status rebuild")

  vim.fn.delete(repo, "rf")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write("fugitive tests failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
print("fugitive tests: OK")
os.exit(0)
