-- Run with `make test` (nvim --headless -l tests/test_reviewer.lua).
vim.opt.rtp:append(vim.fn.getcwd())

local store = require("reviewer.store")
local send = require("reviewer.send")
local location = require("reviewer.location")

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
  assert(not send.generate_markdown():find("`~`", 1, true), "no old-side clause without old-side comments")
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

  -- Multi-line comments cover every selected line and format as start-end.
  local range = store.add("src/a.lua", 10, "spans lines", "new", 14)
  eq(range.end_line, 14, "range keeps its last line")
  eq(store.add("src/a.lua", 20, "single", "new", 20).end_line, nil, "one-line selection is a plain comment")
  eq(store.get_at_line("src/a.lua", 12, "new").text, "spans lines", "range matches a line inside it")
  eq(store.get_at_line("src/a.lua", 15, "new"), nil, "range does not match the line after it")
  eq(location.format(range), "src/a.lua:10-14", "range location")
  eq(location.format({ file = "f", line = 10, end_line = 14, side = "old" }), "f:~10-14", "old-side range location")
  local range_md = send.generate_markdown()
  assert(range_md:find("src/a.lua:10-14", 1, true), "range location in the payload")

  -- Range marks: sign on the first line, box under the last, highlight between.
  local marks = require("reviewer.marks")
  local marks_buf = vim.api.nvim_create_buf(false, true)
  local marks_lines = {}
  for i = 1, 25 do
    marks_lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(marks_buf, 0, -1, false, marks_lines)
  marks.render_for_buffer(marks_buf, "new", "src/a.lua")
  local ns = vim.api.nvim_create_namespace("reviewer")
  local sign_found, box_found, highlight_found = false, false, false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(marks_buf, ns, 0, -1, { details = true })) do
    local row, details = mark[2], mark[4]
    if row == 9 and details.sign_text then
      sign_found = true
    end
    if row == 13 and details.virt_lines then
      box_found = true
    end
    if row == 9 and details.end_row == 14 and details.hl_group == "ReviewerRange" then
      highlight_found = true
    end
  end
  eq(sign_found, true, "range sign on the first line")
  eq(box_found, true, "comment box under the last line")
  eq(highlight_found, true, "range highlight covers the selected lines")

  local files = vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*feature-x.json", false, true)
  eq(#files, 1, "one branch-scoped store file")

  -- Successful send clears the store and the file. The payload is sidekick text
  -- chunks, so flatten them the way sidekick does.
  local sent
  local sent_opts
  local function flatten(text)
    local out = {}
    for _, line in ipairs(text or {}) do
      local parts = {}
      for _, chunk in ipairs(line) do
        parts[#parts + 1] = chunk[1]
      end
      out[#out + 1] = table.concat(parts)
    end
    return table.concat(out, "\n")
  end
  package.loaded["sidekick.cli"] = {
    send = function(opts)
      sent_opts = opts
      sent = flatten(opts.text)
    end,
  }
  send.setup({ tool = "copilot" })
  send.to_sidekick()
  assert(sent and sent:find("line one second line", 1, true), "payload not sent")
  eq(sent_opts.name, "copilot", "configured tool is passed to sidekick")
  eq(store.count(), 0, "send clears comments")
  eq(#vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*.json", false, true), 0, "send removes store file")

  -- Without sidekick's location context, positions fall back to the plain form.
  store.add("src/a.lua", 3, "no context module")
  send.to_sidekick()
  assert(sent:find("`src/a.lua:3`", 1, true), "plain fallback location")
  assert(not sent:find("`~`", 1, true), "chunk header omits the old-side clause without old comments")

  -- With it, each comment carries a file reference built from the repo root.
  local calls = {}
  package.loaded["sidekick.cli.context.location"] = {
    get = function(ctx, o)
      calls[#calls + 1] = { ctx = ctx, kind = o and o.kind }
      local ref = { { "@" .. ctx.name } }
      if ctx.range then
        ref[1][1] = ref[1][1] .. " :L" .. ctx.range.from[1]
      end
      return { ref }
    end,
  }
  store.add("src/a.lua", 7, "referenced")
  store.add("src/b.lua", 0, "whole file")
  store.add("src/c.lua", 2, "old side", "old")
  send.to_sidekick()
  assert(sent:find("@" .. root .. "/src/a.lua :L7", 1, true), "mention uses the repo root")
  eq(calls[1].kind, "line", "line-level reference")
  eq(calls[1].ctx.range.from[1], 7, "reference starts at the comment line")
  eq(calls[2].ctx.range, nil, "file comment has no range")
  eq(#calls, 2, "old-side comments are not referenced")
  assert(sent:find("@" .. root .. "/src/b.lua", 1, true), "file comment references the whole file")
  assert(sent:find("`src/c.lua:~2`", 1, true), "old-side comments keep the plain form")
  assert(sent:find("`~` = old side", 1, true), "chunk header explains old-side comments")
  package.loaded["sidekick.cli.context.location"] = nil

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
  -- disables an action. Stub the codediff lifecycle the keymapper reads, as an
  -- inline-layout session: only the modified buffer exists.
  local keymaps = require("reviewer.keymaps")
  local km_buf = vim.api.nvim_create_buf(false, true)
  package.preload["codediff.ui.lifecycle"] = function()
    return {
      get_buffers = function()
        return nil, km_buf
      end,
      get_windows = function() end,
    }
  end

  keymaps.setup({ add_comment = "gC", next_comment = false })
  keymaps.setup_keymaps(0)
  local function has_map(lhs, mode)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(km_buf, mode or "n")) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end

  eq(has_map("gC"), true, "custom key is buffer-local")
  eq(has_map("gC", "x"), true, "add_comment is also mapped in visual mode")
  eq(has_map("]n", "x"), false, "other keys are not mapped in visual mode")
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

  -- Visual range is normalized whichever way the selection was made.
  local comments = require("reviewer.comments")
  vim.fn.setpos("'<", { 0, 12, 1, 0 })
  vim.fn.setpos("'>", { 0, 8, 1, 0 })
  local range_start, range_end = comments._visual_range()
  eq(range_start, 8, "visual range starts at the lower line")
  eq(range_end, 12, "visual range ends at the higher line")

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

  -- Visual-mode add stores the selection as a range through the popup.
  local popup = require("reviewer.popup")
  local popup_open = popup.open
  popup.open = function(_, callback)
    callback("range note")
  end
  vim.fn.setpos("'<", { 0, 2, 1, 0 })
  vim.fn.setpos("'>", { 0, 5, 1, 0 })
  comments.add_range()
  popup.open = popup_open
  local ranged = store.get_at_line("bar.lua", 3, "new")
  assert(ranged, "range comment not stored")
  eq(ranged.line, 2, "range comment starts at the selection start")
  eq(ranged.end_line, 5, "range comment ends at the selection end")
  eq(location.format(ranged), "bar.lua:2-5", "range comment location")
  store.delete(ranged.id)

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
