-- Run with `make test` (nvim --headless -l tests/test_reviewer.lua).
vim.opt.rtp:append(vim.fn.getcwd())

local store = require("reviewer.store")
local send = require("reviewer.send")

local function eq(actual, expected, msg)
  assert(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

local function main()
  -- A throwaway repo so the store has a real branch and root to key off.
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  local function git(...)
    local args = { "git", "-C", repo, ... }
    local out = vim.fn.systemlist(args)
    assert(vim.v.shell_error == 0, "git failed: " .. table.concat(args, " ") .. "\n" .. table.concat(out, "\n"))
    return out
  end
  git("init", "-q")
  git("config", "user.email", "test@example.com")
  git("config", "user.name", "test")
  vim.fn.writefile({ "a" }, repo .. "/a.lua")
  git("add", "a.lua")
  git("commit", "-qm", "init")
  git("checkout", "-qb", "feature-x")
  local root = git("rev-parse", "--show-toplevel")[1]

  -- Run from an unrelated cwd: set_repo must still find the reviewed repo.
  local neutral = vim.fn.tempname()
  vim.fn.mkdir(neutral, "p")
  vim.fn.chdir(neutral)

  store.set_repo(root)
  store.load()
  eq(store.count(), 0, "fresh store")

  store.add("src/a.lua", 3, "line one\nsecond line", "new")
  store.add("src/a.lua", 7, "old impl", "old")
  store.add("src/b.lua", 0, "file note")
  eq(store.count(), 3, "count after add")
  eq(store.get_at_line("src/a.lua", 3, "new").text, "line one\nsecond line", "stored text")
  eq(store.get_file_comment("src/b.lua").line, 0, "file comment line")
  eq(#store.get_for_file("src/a.lua", "old"), 1, "old-side filter")
  eq(#store.get_for_file("src/b.lua", "old"), 1, "file comment shows on old side")
  eq(#store.get_for_file("src/b.lua", "new"), 1, "file comment shows on new side")

  local md = send.generate_markdown()
  assert(md:find("src/a.lua:3", 1, true), "missing new-side location")
  assert(md:find("src/a.lua:~7", 1, true), "missing old-side location")
  assert(md:find("src/b.lua", 1, true), "missing file-level location")
  assert(md:find("line one second line", 1, true), "newlines should flatten to a space")
  assert(not md:find("\nsecond line", 1, true), "comment text must stay on one line")

  local files = vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*feature-x.json", false, true)
  eq(#files, 1, "one branch-scoped store file")

  -- Successful send clears the store and the file.
  local sent
  local sent_opts
  package.loaded["sidekick.cli"] = {
    send = function(opts)
      sent_opts = opts
      sent = opts.msg
    end,
  }
  send.setup({ tool = "copilot" })
  send.to_sidekick()
  assert(sent and sent:find("line one second line", 1, true), "payload not sent")
  eq(sent_opts.name, "copilot", "configured tool is passed to sidekick")
  eq(store.count(), 0, "send clears comments")
  eq(#vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*.json", false, true), 0, "send removes store file")

  -- Without a configured tool, sidekick picks its own.
  store.add("src/a.lua", 1, "no tool")
  send.setup({})
  send.to_sidekick()
  eq(sent_opts.name, nil, "no tool option leaves the name to sidekick")

  -- The public option lives under `sidekick.tool`.
  require("reviewer").setup({ sidekick = { tool = "claude" } })
  store.add("src/a.lua", 1, "nested option")
  send.to_sidekick()
  eq(sent_opts.name, "claude", "setup forwards sidekick.tool")

  -- Keymap options override defaults, keep unset defaults, and `false`
  -- disables an action. Stub the codediff lifecycle the keymapper reads.
  local keymaps = require("reviewer.keymaps")
  local km_buf = vim.api.nvim_create_buf(false, true)
  package.preload["codediff.ui.lifecycle"] = function()
    return {
      get_buffers = function()
        return km_buf, km_buf
      end,
      get_windows = function() end,
    }
  end

  keymaps.setup({ add_comment = "gC", next_comment = false })
  keymaps.setup_keymaps(0)
  local function has_map(lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(km_buf, "n")) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  eq(has_map("gC"), true, "custom key is buffer-local")
  eq(has_map("]n"), false, "disabled key is not mapped")
  eq(has_map("[n"), true, "unset key keeps its default")

  keymaps.setup({})
  keymaps.setup_keymaps(0)
  eq(has_map("gC"), false, "reset drops the custom key")
  eq(has_map("]n"), true, "reset restores the default key")
  eq(has_map((vim.g.maplocalleader or "\\") .. "a"), true, "default add_comment uses localleader")

  keymaps.setup({ edit_comment = "" })
  keymaps.setup_keymaps(0)
  eq(has_map((vim.g.maplocalleader or "\\") .. "e"), false, "empty key is not mapped")

  keymaps.cleanup()
  package.loaded["codediff.ui.lifecycle"] = nil
  package.preload["codediff.ui.lifecycle"] = nil

  -- Cursor position: window matching plus the virtual-buffer / inline fallback.
  local hooks = require("reviewer.hooks")
  local cur_win = vim.api.nvim_get_current_win()
  local cur_buf = vim.api.nvim_get_current_buf()
  local buf_lines = {}
  for i = 1, 10 do
    buf_lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(cur_buf, 0, -1, false, buf_lines)
  vim.api.nvim_buf_set_name(cur_buf, "codediff:///repo///HEAD/foo.lua")
  vim.api.nvim_win_set_cursor(cur_win, { 7, 0 })

  local hk = {
    get_session = function()
      return { modified_win = cur_win }
    end,
    get_buffers = function()
      return cur_buf, cur_buf
    end,
    get_paths = function()
      return nil, nil
    end,
    get_windows = function()
      return nil, cur_win
    end,
    get_git_context = function()
      return { git_root = "/repo" }
    end,
  }
  package.loaded["codediff.ui.lifecycle"] = hk
  package.preload["codediff.core.virtual_file"] = function()
    return {
      parse_url = function()
        return "/repo", "HEAD", "foo.lua"
      end,
    }
  end

  -- Inline open: paths are empty, so the path comes from the buffer name.
  hooks.on_file_changed(vim.api.nvim_get_current_tabpage())
  local file, line, side = hooks.get_cursor_position()
  eq(file, "foo.lua", "virtual buffer path resolved from the buffer name")
  eq(line, 7, "cursor position reports the cursor line")
  eq(side, "new", "modified window reports the new side")

  -- Same virtual path, but the cursor sits in the original window.
  hk.get_windows = function()
    return cur_win, nil
  end
  file, line, side = hooks.get_cursor_position()
  eq(file, "foo.lua", "original pane resolves the same path")
  eq(line, 7, "cursor line holds on the original side")
  eq(side, "old", "original window reports the old side")

  -- A real path from get_paths wins over the buffer-name fallback.
  hk.get_windows = function()
    return nil, cur_win
  end
  hk.get_paths = function()
    return nil, { absolute = "/repo/bar.lua" }
  end
  file, line, side = hooks.get_cursor_position()
  eq(file, "bar.lua", "lifecycle path wins when present")
  eq(line, 7, "cursor line holds with a real path")
  eq(side, "new", "real path on the modified side")

  package.loaded["codediff.core.virtual_file"] = nil
  package.preload["codediff.core.virtual_file"] = nil
  package.loaded["codediff.ui.lifecycle"] = nil

  -- A failing send must keep the comments.
  store.add("src/a.lua", 5, "keep me")
  package.loaded["sidekick.cli"] = {
    send = function()
      error("boom")
    end,
  }
  send.to_sidekick()
  eq(store.count(), 1, "failed send keeps comments")

  -- Switching branches in the same repo must not leak comments across branches.
  git("checkout", "-qb", "feature-y")
  store.set_repo(root)
  store.load()
  eq(store.count(), 0, "no leak into another branch")
  store.add("src/a.lua", 1, "branch y note")
  local y_files = vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*feature-y.json", false, true)
  eq(#y_files, 1, "branch-scoped store file for second branch")

  git("checkout", "-q", "feature-x")
  store.set_repo(root)
  store.load()
  eq(store.count(), 1, "original branch comments survive a branch round-trip")
  eq(store.get_all()[1].text, "keep me", "branch comments are isolated, not merged")

  vim.fn.chdir(repo)
  vim.fn.delete(repo, "rf")
  vim.fn.delete(neutral, "rf")
end

local ok, err = pcall(main)
if not ok then
  io.stderr:write("reviewer tests failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
print("reviewer tests: OK")
os.exit(0)
