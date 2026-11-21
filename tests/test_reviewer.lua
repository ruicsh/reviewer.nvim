-- Run with `make test` (nvim --headless -l tests/test_reviewer.lua).
vim.opt.rtp:append(vim.fn.getcwd())

local store = require("reviewer.store")
local send = require("reviewer.send")
local location = require("reviewer.location")
local fugitive = require("reviewer.sources.fugitive")
local hooks = require("reviewer.hooks")

local function eq(actual, expected, msg)
  assert(actual == expected, string.format("%s: expected %s, got %s", msg, tostring(expected), tostring(actual)))
end

local function main()
  -- Fugitive status buffer: cursor line -> real file line, side, and scope.
  -- Expanded hunks are the real unified diff, so the `@@` header and the
  -- sigils are enough to derive a position.
  local status = {
    "Head: main", -- 1
    "", -- 2
    "Staged (1)", -- 3
    "M src/a.lua", -- 4
    "@@ -10,2 +10,3 @@", -- 5
    " context ten", -- 6
    "+added eleven", -- 7
    " context twelve", -- 8
    "@@ -20,1 +21,1 @@", -- 9
    "-old twenty", -- 10
    "+new twenty", -- 11
    "", -- 12
    "Unstaged (1)", -- 13
    "M src/b.lua", -- 14
    "@@ -30,1 +30,1 @@", -- 15
    "-gone", -- 16
    "\\ No newline at end of file", -- 17
    "+back", -- 18
  }

  local function eq_pos(lnum, file, line, side, scope)
    local p = fugitive.derive(status, lnum)
    assert(p, "no position at status line " .. lnum)
    eq(p.file, file, "file at status line " .. lnum)
    eq(p.line, line, "file line at status line " .. lnum)
    eq(p.side, side, "side at status line " .. lnum)
    eq(p.scope, scope, "scope at status line " .. lnum)
  end

  local function eq_nil_pos(lnum)
    eq(fugitive.derive(status, lnum), nil, "no position at status line " .. lnum)
  end

  eq_pos(6, "src/a.lua", 10, "new", "staged")
  eq_pos(7, "src/a.lua", 11, "new", "staged")
  -- Context lines advance both sides: old 10..11, new 10..12.
  eq_pos(8, "src/a.lua", 12, "new", "staged")
  eq_pos(10, "src/a.lua", 20, "old", "staged")
  eq_pos(11, "src/a.lua", 21, "new", "staged")
  eq_pos(4, "src/a.lua", 0, "new", "staged")
  eq_pos(14, "src/b.lua", 0, "new", "unstaged")
  -- A `\ No newline` marker belongs to no line, and the line after it still
  -- resolves: old 30 was consumed by the deletion only.
  eq_nil_pos(17)
  eq_pos(18, "src/b.lua", 30, "new", "unstaged")
  -- Headers, headings, blanks, and the head summary are not comment targets.
  eq_nil_pos(5)
  eq_nil_pos(3)
  eq_nil_pos(12)
  eq_nil_pos(1)
  -- A hunk with no file entry above it is not part of the status list.
  eq(fugitive.derive({ "@@ -1,1 +1,1 @@", "+orphan" }, 2), nil, "hunk without a file entry")

  -- A file entry is the file-comment anchor; a hunk line, even one that maps
  -- to file line 1, is a line comment. This keeps `a` on fugitive line 1 from
  -- colliding with the file comment.
  eq(fugitive.derive(status, 4).at_file_anchor, true, "file entry is the file-comment anchor")
  eq(
    fugitive.derive({ "Staged (1)", "M src/a.lua", "@@ -1,1 +1,1 @@", "+first" }, 4).at_file_anchor,
    nil,
    "file line 1 is not the file-comment anchor"
  )

  -- codediff's first buffer row is both file line 1 and the file-comment anchor,
  -- so only there does `a` consult the file comment.
  local codediff_source = require("reviewer.sources.codediff")
  local hook_mod = require("reviewer.hooks")
  local orig_get_cursor = hook_mod.get_cursor_position
  hook_mod.get_cursor_position = function()
    return "src/a.lua", 1, "new"
  end
  eq(codediff_source.position(0).at_file_anchor, true, "codediff line 1 is a file-comment anchor")
  hook_mod.get_cursor_position = function()
    return "src/a.lua", 2, "new"
  end
  eq(codediff_source.position(0).at_file_anchor, false, "codediff line 2 is not a file-comment anchor")
  hook_mod.get_cursor_position = orig_get_cursor

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

  -- Multi-line comments cover every selected line and format as start-end.
  local range = store.add("src/a.lua", 10, "spans lines", "new", 14)
  eq(range.end_line, 14, "range keeps its last line")
  eq(store.add("src/a.lua", 20, "single", "new", 20).end_line, nil, "one-line selection is a plain comment")
  eq(store.get_at_line("src/a.lua", 12, "new").text, "spans lines", "range matches a line inside it")
  eq(store.get_at_line("src/a.lua", 15, "new"), nil, "range does not match the line after it")
  eq(location.format(range), "src/a.lua:10-14", "range location")
  eq(location.format({ file = "f", line = 10, end_line = 14, side = "old" }), "f:~10-14", "old-side range location")

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

  -- Scoped comments: the same file line staged and unstaged are two different
  -- comments, and the location names the scope.
  local staged = store.add("src/a.lua", 50, "staged note", "new", nil, "staged")
  local unstaged = store.add("src/a.lua", 50, "unstaged note", "new", nil, "unstaged")
  eq(store.get_at_line("src/a.lua", 50, "new", "staged").text, "staged note", "staged comment is addressable")
  eq(store.get_at_line("src/a.lua", 50, "new", "unstaged").text, "unstaged note", "unstaged comment is addressable")
  eq(store.get_at_line("src/a.lua", 50, "new"), nil, "unscoped lookup ignores scoped comments")
  eq(location.format(staged), "src/a.lua:50 (staged)", "scope is part of the location")
  eq(location.format(unstaged), "src/a.lua:50 (unstaged)", "each scope keeps its own location")
  assert(send.generate_markdown():find("src/a.lua:50 (staged)", 1, true), "scope in the payload")
  store.delete(staged.id)
  store.delete(unstaged.id)

  -- codediff scope: a pane that shows the index or a commit must not share a
  -- comment identity with the working tree. The new side decides what the pane
  -- shows, so a nil (or WORKING) target is the working tree and stays unscoped.
  eq(hooks.scope(nil), nil, "no session has no scope")
  eq(hooks.scope({ original_revision = "HEAD" }), nil, "working tree is unscoped")
  eq(hooks.scope({ original_revision = "HEAD", modified_revision = "WORKING" }), nil, "WORKING is unscoped")
  eq(hooks.scope({ original_revision = "HEAD", modified_revision = ":0" }), "staged", "index pane is staged")
  eq(hooks.scope({ original_revision = ":3", modified_revision = ":2" }), "conflict:2", "conflict side is scoped")
  eq(
    hooks.scope({ original_revision = "abc1234^", modified_revision = "abc1234" }),
    "commit:abc1234",
    "commit pairs name the commit"
  )
  eq(
    hooks.scope({ original_revision = "abc1234", modified_revision = "def5678" }),
    "rev:abc1234..def5678",
    "two-revision diffs name both sides"
  )
  eq(hooks.scope({ modified_revision = "abc1234" }), "commit:abc1234", "single-side commit is scoped")
  eq(
    hooks.scope({ original_revision = "0123456789abcdef", modified_revision = "fedcba9876543210" }),
    "rev:0123456..fedcba9",
    "hashes are shortened like git does"
  )

  -- Same file line, working tree and commit: two comments, two locations.
  local wt = store.add("src/a.lua", 18, "wt note")
  local commit = store.add("src/a.lua", 18, "commit note", "new", nil, "commit:abc1234")
  eq(store.get_at_line("src/a.lua", 18, "new").text, "wt note", "working-tree lookup ignores the commit comment")
  eq(store.get_at_line("src/a.lua", 18, "new", "commit:abc1234").text, "commit note", "commit comment is addressable")
  eq(location.format(commit), "src/a.lua:18 (commit:abc1234)", "commit scope in the location")
  assert(send.generate_markdown():find("src/a.lua:18 (commit:abc1234)", 1, true), "commit scope in the payload")

  -- Marks follow the pane's slice: the same row carries one comment or the
  -- other, never both.
  local function box_text(row)
    local out = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(marks_buf, ns, 0, -1, { details = true })) do
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
  marks.render_for_buffer(marks_buf, "new", "src/a.lua")
  assert(box_text(17):find("wt note", 1, true), "working-tree pane draws the working-tree comment")
  assert(not box_text(17):find("commit note", 1, true), "working-tree pane hides the commit comment")
  marks.render_for_buffer(marks_buf, "new", "src/a.lua", "commit:abc1234")
  assert(box_text(17):find("commit note", 1, true), "commit pane draws the commit comment")
  assert(not box_text(17):find("wt note", 1, true), "commit pane hides the working-tree comment")
  store.delete(wt.id)
  store.delete(commit.id)

  -- A fugitive status buffer: positions are derived from the buffer text, so a
  -- comment lands on its hunk line, and a collapsed hunk keeps its count on the
  -- file's entry line instead of disappearing.
  local fug_comments = {
    { id = "a", file = "src/a.lua", line = 11, side = "new", scope = "staged", text = "added" },
    { id = "b", file = "src/a.lua", line = 20, side = "old", scope = "staged", text = "removed" },
    { id = "c", file = "src/b.lua", line = 0, side = "new", scope = "unstaged", text = "file note" },
    { id = "d", file = "src/a.lua", line = 40, side = "new", scope = "staged", text = "collapsed" },
    { id = "e", file = "src/a.lua", line = 10, side = "new", scope = "staged", text = "ranged", end_line = 12 },
  }
  local runs, hidden = fugitive.positions(status, fug_comments)
  local by_id = {}
  for _, run in ipairs(runs) do
    by_id[run.comment.id] = run
  end
  eq(by_id.a.row, 6, "comment box on the added line")
  eq(by_id.b.row, 9, "old-side comment box on the removed line")
  eq(by_id.c.row, 13, "file comment box on the entry line")
  eq(by_id.e.row, 5, "range starts on its first visible line")
  eq(by_id.e.last_row, 7, "range ends on its last visible line")
  eq(hidden[3], 1, "collapsed hunk counts on the file entry")
  eq(hidden[13], nil, "a visible file comment is not counted as hidden")

  -- A selection maps to file lines only when every selected row shares one
  -- file, scope, and side.
  local range_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(range_buf, 0, -1, false, status)
  local restore_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(range_buf)
  local within = fugitive.range(6, 8)
  eq(within and within.file, "src/a.lua", "range file")
  eq(within and within.line, 10, "range starts at the first new-side line")
  eq(within and within.end_line, 12, "range ends at the last new-side line")
  eq(within and within.side, "new", "range side")
  eq(within and within.scope, "staged", "range scope")
  eq(fugitive.range(10, 11), nil, "a range over both sides is refused")
  eq(fugitive.range(5, 8), nil, "a range over a hunk header is refused")
  eq(fugitive.range(14, 14), nil, "a range on a file entry line is refused")
  vim.api.nvim_set_current_buf(restore_buf)
  vim.api.nvim_buf_delete(range_buf, { force = true })

  -- Render it: the box goes on the derived row, not on a stored buffer line.
  local prev_buf = vim.api.nvim_get_current_buf()
  local fug_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(fug_buf, 0, -1, false, status)
  vim.bo[fug_buf].filetype = "fugitive"
  vim.b[fug_buf].fugitive_type = "index"

  local hunk_comment = store.add("src/a.lua", 11, "on the hunk", "new", nil, "staged")
  marks.render_fugitive(fug_buf)
  local fug_box = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(fug_buf, ns, 0, -1, { details = true })) do
    if mark[2] == 6 and mark[4].virt_lines then
      fug_box = true
    end
  end
  eq(fug_box, true, "comment box on the hunk line")
  store.delete(hunk_comment.id)

  -- A file comment and a collapsed line comment share the file's entry row: the
  -- box stays, and the hidden count rides along instead of losing its sign to
  -- the visible one.
  local file_comment = store.add("src/a.lua", 0, "file note", "new", nil, "staged")
  local collapsed_comment = store.add("src/a.lua", 40, "collapsed", "new", nil, "staged")
  marks.render_fugitive(fug_buf)
  local entry_box, entry_count = false, false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(fug_buf, ns, 0, -1, { details = true })) do
    if mark[2] == 3 and mark[4].virt_lines then
      entry_box = true
      for _, virt_line in ipairs(mark[4].virt_lines) do
        if virt_line[1] and virt_line[1][1]:find("in a collapsed hunk", 1, true) then
          entry_count = true
        end
      end
    end
  end
  eq(entry_box, true, "file comment box on the entry line")
  eq(entry_count, true, "collapsed count rides along with the file comment")
  store.delete(file_comment.id)
  store.delete(collapsed_comment.id)

  -- The status buffer resolves to its own source, and the cursor maps back to a
  -- real file line with a scope.
  vim.api.nvim_set_current_buf(fug_buf)
  vim.api.nvim_win_set_cursor(0, { 7, 0 })
  local resolved = require("reviewer.sources").resolve()
  eq(resolved and resolved.name, "fugitive", "status buffer resolves to the fugitive source")
  local fug_pos = require("reviewer.position").get()
  eq(fug_pos.file, "src/a.lua", "file derived from the status buffer")
  eq(fug_pos.line, 11, "file line derived from the status buffer")
  eq(fug_pos.side, "new", "side derived from the sigil")
  eq(fug_pos.scope, "staged", "scope derived from the section heading")

  vim.api.nvim_set_current_buf(prev_buf)
  vim.api.nvim_buf_delete(fug_buf, { force = true })

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
  assert(sent:find("1. `src/a.lua:3`\nline one second line\n\n", 1, true), "reference line then text then a blank line")
  assert(not sent:find("\nsecond line", 1, true), "comment text must stay on one line")
  assert(sent:find("`src/a.lua:~7`", 1, true), "old-side location in the payload")
  assert(sent:find("`src/b.lua`", 1, true), "file-level location in the payload")
  assert(sent:find("`src/a.lua:10-14`", 1, true), "range location in the payload")
  eq(sent_opts.name, "copilot", "configured tool is passed to sidekick")
  eq(store.count(), 0, "send clears comments")
  eq(#vim.fn.glob(vim.fn.stdpath("data") .. "/reviewer/*.json", false, true), 0, "send removes store file")

  -- A comment records the code at its line and the HEAD it was written at, so a
  -- later send can tell when the agent moved that code.
  vim.fn.writefile({ "local one = 1", "local two = 2", "local three = 3" }, repo .. "/anchored.lua")
  git("add", "anchored.lua")
  git("commit", "-qm", "anchor base")
  store.add("anchored.lua", 2, "check this")
  local anchored = store.get_all()[1]
  eq(anchored.excerpt, "local two = 2", "excerpt captures the commented line")
  eq(anchored.head, git("rev-parse", "--short", "HEAD")[1], "comment records its HEAD")
  eq(#send.find_drifted(store.get_all()), 0, "an unchanged line is not drifted")
  local anchored_md = send.generate_markdown()
  assert(anchored_md:find("> local two = 2", 1, true), "payload quotes the commented line")
  assert(
    anchored_md:find("Review made against HEAD " .. anchored.head .. " on branch feature-x.", 1, true),
    "payload names the HEAD and branch the line numbers refer to"
  )

  -- Only a new-side line over the working tree or the index can be read back;
  -- an old-side line has no file to compare against.
  local old_anchor = store.add("anchored.lua", 2, "old note", "old")
  eq(old_anchor.excerpt, nil, "old-side comments carry no anchor")
  store.delete(old_anchor.id)

  -- The agent rewrote the line: the comment now points at different code, and
  -- sending asks first.
  vim.fn.writefile({ "local one = 1", "local TWO = 2", "local three = 3" }, repo .. "/anchored.lua")
  eq(#send.find_drifted(store.get_all()), 1, "an edited line is drifted")
  local orig_confirm = vim.fn.confirm
  local asked
  vim.fn.confirm = function(msg)
    asked = msg
    return 2
  end
  send.to_sidekick()
  assert(asked and asked:find("no longer match", 1, true), "a drifted comment asks before sending")
  eq(store.count(), 1, "cancelling the prompt keeps the comments")

  -- Confirming sends anyway; the quoted line still shows what was reviewed.
  vim.fn.confirm = function()
    return 1
  end
  send.to_sidekick()
  vim.fn.confirm = orig_confirm
  assert(sent:find("> local two = 2", 1, true), "the stale payload keeps the reviewed line")
  eq(store.count(), 0, "sending anyway clears the comments")

  -- Comments from two commits name both heads, without claiming the current
  -- branch for the older one.
  vim.fn.writefile({ "v1" }, repo .. "/head-anchor.lua")
  git("add", "head-anchor.lua")
  git("commit", "-qm", "head one")
  store.add("head-anchor.lua", 1, "first")
  vim.fn.writefile({ "v2" }, repo .. "/head-anchor.lua")
  git("add", "head-anchor.lua")
  git("commit", "-qm", "head two")
  store.add("head-anchor.lua", 1, "second")
  local multi_head = send.generate_markdown():match("Comments were made against HEAD [^\n]+")
  assert(multi_head, "two heads are named in the header")
  assert(not multi_head:find("on branch", 1, true), "multiple heads do not name the current branch")
  store.clear()

  -- A staged comment is anchored to the index, so working-tree edits alone are
  -- not drift, but a new `git add` is.
  vim.fn.writefile({ "staged one", "staged two" }, repo .. "/staged-anchor.lua")
  git("add", "staged-anchor.lua")
  store.add("staged-anchor.lua", 2, "staged note", "new", nil, "staged")
  eq(store.get_all()[1].excerpt, "staged two", "staged excerpt comes from the index")
  vim.fn.writefile({ "staged one", "staged TWO" }, repo .. "/staged-anchor.lua")
  eq(#send.find_drifted(store.get_all()), 0, "working-tree edits do not drift a staged comment")
  git("add", "staged-anchor.lua")
  eq(#send.find_drifted(store.get_all()), 1, "a rewritten index line is drifted")

  -- A range is anchored by its first line, and the prompt says so instead of
  -- implying the whole range was re-checked.
  vim.fn.writefile({ "range one", "range two" }, repo .. "/range-anchor.lua")
  store.add("range-anchor.lua", 1, "range note", "new", 2)
  vim.fn.writefile({ "RANGE one", "range two" }, repo .. "/range-anchor.lua")
  vim.fn.confirm = function(msg)
    asked = msg
    return 2
  end
  send.to_sidekick()
  vim.fn.confirm = orig_confirm
  assert(
    asked and asked:find("first line of a multi-line comment", 1, true),
    "a drifted range explains which line is compared"
  )
  store.clear()

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
  assert(
    sent:find("@" .. root .. "/src/a.lua :L7\nreferenced\n\n", 1, true),
    "reference line is followed by the comment text and a blank line"
  )
  eq(calls[1].kind, "line", "line-level reference")
  eq(calls[1].ctx.range.from[1], 7, "reference starts at the comment line")
  eq(calls[2].ctx.range, nil, "file comment has no range")
  eq(#calls, 2, "old-side comments are not referenced")
  assert(sent:find("@" .. root .. "/src/b.lua\nwhole file\n\n", 1, true), "file comment references the whole file")
  assert(sent:find("`src/c.lua:~2`", 1, true), "old-side comments keep the plain form")
  assert(sent:find("`~` = old side", 1, true), "chunk header explains old-side comments")

  -- A revision comment keeps the plain form even with location context: only
  -- the plain form names the commit the line lives in.
  local calls_before = #calls
  store.add("src/a.lua", 7, "scoped", "new", nil, "commit:abc1234")
  send.to_sidekick()
  assert(sent:find("`src/a.lua:7 (commit:abc1234)`", 1, true), "revision comment keeps its scope in the payload")
  eq(#calls, calls_before, "a revision comment is not made into a working-tree reference")
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

  -- A buffer attached by another source keeps its keys when a codediff session
  -- switches files or closes: only the session's own buffers are torn down.
  local other_buf = vim.api.nvim_create_buf(false, true)
  local function has_map_buf(bufnr, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs then
        return true
      end
    end
    return false
  end
  local add_key = (vim.g.maplocalleader or "\\") .. "a"
  keymaps.attach(other_buf)
  eq(has_map_buf(other_buf, add_key), true, "attach maps a single buffer")
  keymaps.setup_keymaps(0)
  eq(has_map_buf(other_buf, add_key), true, "a session switch keeps another source's keys")
  keymaps.cleanup_session()
  eq(has_map_buf(other_buf, add_key), true, "a session close keeps another source's keys")
  keymaps.cleanup()
  eq(has_map_buf(other_buf, add_key), false, "cleanup drops every attachment")
  vim.api.nvim_buf_delete(other_buf, { force = true })

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

  -- The source reports the revision slice of the pane, so a commit review does
  -- not store its comments as working-tree comments.
  hk.get_git_context = function()
    return { git_root = "/repo", original_revision = "abc1234^", modified_revision = "abc1234" }
  end
  eq(codediff_source.position(0).scope, "commit:abc1234", "codediff position carries the pane's scope")
  hk.get_git_context = function()
    return { git_root = "/repo" }
  end
  eq(codediff_source.position(0).scope, nil, "working-tree panes stay unscoped")

  -- Jumping to a comment from another slice: the file can be selected, but a
  -- fixed revision cannot appear there, so the jump says what it cannot show.
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg)
    table.insert(notes, msg)
  end
  local unshowable = { file = "bar.lua", line = 7, side = "new", scope = "staged", text = "x" }
  codediff_source.jump(unshowable)
  eq(#notes, 1, "a jump to another slice warns")
  assert(notes[1]:find("staged", 1, true), "the warning names the slice")

  -- An explorer re-resolves the file's group on selection, so staged/unstaged
  -- jumps need no warning there; another revision still does.
  notes = {}
  local explorer = { tree = {}, on_file_select = function() end }
  hk.get_explorer = function()
    return explorer
  end
  package.loaded["codediff.ui.explorer.tree"] = {
    get_all_files = function()
      return { { data = { path = "bar.lua" } } }
    end,
  }
  codediff_source.jump(unshowable)
  eq(#notes, 0, "an explorer resolves staged and unstaged without a warning")
  codediff_source.jump({ file = "bar.lua", line = 7, side = "new", scope = "commit:abc1234", text = "x" })
  eq(#notes, 1, "a commit comment in a working-tree review warns")
  assert(notes[1]:find("commit:abc1234", 1, true), "the warning names the commit")
  hk.get_explorer = nil
  package.loaded["codediff.ui.explorer.tree"] = nil
  vim.notify = orig_notify

  -- A history entry diffs a commit against its parent, but the comment is about
  -- the commit: the scope names one revision the agent can `git show`.
  local base_session = hk.get_session
  hk.get_session = function()
    return { panel = { name = "history", data = { parents = { ["abc1234"] = { "def5678" } } } } }
  end
  hk.get_git_context = function()
    return { original_revision = "def5678", modified_revision = "abc1234" }
  end
  eq(hooks.scope_for(0), "commit:abc1234", "a history entry names its commit")
  hk.get_git_context = function()
    return { original_revision = "1111111", modified_revision = "abc1234" }
  end
  eq(hooks.scope_for(0), "rev:1111111..abc1234", "a revision comparison names both sides")
  hk.get_session = base_session
  hk.get_git_context = function()
    return { git_root = "/repo" }
  end

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

  -- Silence info and warning messages; errors still show so a failed send is
  -- never invisible.
  local reporter = require("reviewer.notify")
  local seen = {}
  local prev_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(seen, { msg = msg, level = level })
  end
  reporter.setup({ silent = true })
  reporter.notify("info", vim.log.levels.INFO)
  reporter.notify("warn", vim.log.levels.WARN)
  reporter.notify("error", vim.log.levels.ERROR)
  eq(#seen, 1, "silent keeps only errors")
  eq(seen[1].level, vim.log.levels.ERROR, "the surviving message is the error")
  reporter.setup({})
  reporter.notify("back", vim.log.levels.INFO)
  eq(#seen, 2, "notifications resume once silent is off")
  vim.notify = prev_notify

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

  -- Sending: only the index and revisions need the plain `file (scope)` form. A
  -- working-tree scope such as `unstaged` still gets a file reference, and a
  -- file-level commit comment must not short-circuit into one.
  local captured
  package.loaded["sidekick.cli"] = {
    send = function(payload)
      captured = payload.text
    end,
  }
  package.loaded["sidekick.cli.context.location"] = {
    get = function()
      -- A sidekick Text: one line, one chunk. `mention` takes `[1]`.
      return { { { "REF" } } }
    end,
  }
  store.delete(store.get_all()[1].id)
  -- A staged comment can keep a reference while the file has no unstaged edits;
  -- once the working tree moves, the plain form has to name the index.
  vim.fn.writefile({ "one" }, repo .. "/clean.lua")
  git("add", "clean.lua")
  git("commit", "-qm", "clean base")
  vim.fn.writefile({ "one", "two" }, repo .. "/clean.lua")
  git("add", "clean.lua")
  vim.fn.writefile({ "one" }, repo .. "/dirty.lua")
  git("add", "dirty.lua")
  git("commit", "-qm", "dirty base")
  vim.fn.writefile({ "one", "two" }, repo .. "/dirty.lua")
  git("add", "dirty.lua")
  vim.fn.writefile({ "one", "two", "three" }, repo .. "/dirty.lua")

  store.add("src/a.lua", 18, "working tree line")
  store.add("src/a.lua", 19, "unstaged line", "new", nil, "unstaged")
  store.add("src/a.lua", 0, "commit file note", "new", nil, "commit:abc1234")
  store.add("clean.lua", 2, "staged clean note", "new", nil, "staged")
  store.add("dirty.lua", 2, "staged dirty note", "new", nil, "staged")
  send.to_sidekick()
  package.loaded["sidekick.cli.context.location"] = nil

  local chunks = {}
  for _, entry in ipairs(captured) do
    for _, chunk in ipairs(entry) do
      table.insert(chunks, chunk[1])
    end
    table.insert(chunks, "\n")
  end
  local payload = table.concat(chunks)
  local _, refs = payload:gsub("REF", "")
  eq(refs, 3, "unscoped, unstaged, and clean staged comments use a file reference")
  assert(payload:find("dirty.lua:2 (staged)", 1, true), "a staged comment with unstaged edits stays plain")
  assert(not payload:find("clean.lua:2 (staged)", 1, true), "a clean staged comment keeps its reference")
  assert(payload:find("src/a.lua (commit:abc1234)", 1, true), "scoped file comment keeps its scope in the payload")
  assert(payload:find("commit file note", 1, true), "scoped file comment text is sent")
  eq(store.count(), 0, "a successful send clears the comments")

  -- Opening an explorer session leaves the cursor in the file list; reviewer
  -- only moves into the diff pane when no panel owns the focus.
  local pane = vim.api.nvim_get_current_win()
  vim.cmd("vsplit")
  local other = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(pane)
  local fake_lifecycle = {
    get_panel_view = function()
      return { winid = pane, is_hidden = false }
    end,
    get_session = function()
      return { modified_win = other }
    end,
  }
  hooks._focus_modified_pane(fake_lifecycle, 0)
  eq(vim.api.nvim_get_current_win(), pane, "explorer mode keeps focus in the file list")
  fake_lifecycle.get_panel_view = function()
    return { winid = pane, is_hidden = true }
  end
  hooks._focus_modified_pane(fake_lifecycle, 0)
  eq(vim.api.nvim_get_current_win(), other, "a hidden panel lets the diff pane take focus")
  vim.api.nvim_set_current_win(pane)
  fake_lifecycle.get_panel_view = function()
    return nil
  end
  hooks._focus_modified_pane(fake_lifecycle, 0)
  eq(vim.api.nvim_get_current_win(), other, "without a panel the diff pane takes focus")
  vim.api.nvim_win_close(other, true)

  vim.fn.chdir(repo)
  vim.fn.delete(repo, "rf")
  vim.fn.delete(neutral, "rf")
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
  io.stderr:write("reviewer tests failed: " .. tostring(err) .. "\n")
  os.exit(1)
end
print("reviewer tests: OK")
os.exit(0)
