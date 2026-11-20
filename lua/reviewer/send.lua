local M = {}

local store = require("reviewer.store")
local marks = require("reviewer.marks")
local location = require("reviewer.location")

---@type { tool?: string }
local opts = {}

local notify = require("reviewer.notify").notify

---Configure the send target. `tool` is a sidekick tool name (e.g. `copilot`);
---when nil, sidekick uses whichever tool it has selected.
---@param o? { tool?: string }
function M.setup(o)
  opts = o or {}
end

---Explain `~` only when an old-side comment is present: inline diffs cannot
---produce one, and the clause is noise there.
---@param all ReviewerComment[]
---@return string
local function header(all)
  for _, comment in ipairs(all) do
    if (comment.side or "new") == "old" then
      return "Code review comments (`~` = old side)."
    end
  end
  return "Code review comments."
end

---Plain-text markdown payload, the form documented in the README. Sidekick gets
---`payload_text` chunks instead, which can carry file references.
---@param all? ReviewerComment[] defaults to the stored comments
---@return string
function M.generate_markdown(all)
  all = all or store.get_all()
  local lines = { header(all), "" }
  for i, comment in ipairs(all) do
    table.insert(lines, string.format("%d. `%s`", i, location.format(comment)))
    table.insert(lines, (comment.text:gsub("\n", " ")))
    table.insert(lines, "")
  end
  return table.concat(lines, "\n")
end

---Scopes whose new side is the working tree itself. An unstaged or untracked
---line is exactly what a file reference points at; the index, a conflict stage,
---and a commit are not, unless the index still matches the file.
---@param scope string|nil
---@return boolean
local function in_working_tree(scope)
  return scope == nil or scope == "" or scope == "unstaged" or scope == "untracked"
end

---True when the file has no unstaged changes, so the index content a `staged`
---comment refers to is also what the working-tree file holds.
---@param root string
---@param file string
---@param cache table<string, boolean>
---@return boolean
local function index_matches_worktree(root, file, cache)
  local known = cache[file]
  if known ~= nil then
    return known
  end
  vim.fn.system({ "git", "-C", root, "diff", "--quiet", "--", file })
  local clean = vim.v.shell_error == 0
  cache[file] = clean
  return clean
end

---Sidekick text chunks for a comment's position, or nil when the plain form has
---to be used. Mentions point at the working-tree file, so old-side comments keep
---the plain form: their line is gone from it. A staged comment keeps it too while
---the file has unstaged edits, since only the plain form names the index.
---@param Loc table `sidekick.cli.context.location`
---@param comment ReviewerComment
---@param root string repository root
---@param clean table<string, boolean> per-send cache for the index check
---@return sidekick.Text|nil
local function mention(Loc, comment, root, clean)
  if (comment.side or "new") == "old" then
    return nil
  end
  if not in_working_tree(comment.scope) then
    if comment.scope ~= "staged" or not index_matches_worktree(root, comment.file, clean) then
      return nil
    end
  end
  local path = vim.fs.joinpath(root, comment.file)
  if comment.line == 0 then
    return Loc.get({ name = path, cwd = root })[1]
  end
  local last = comment.end_line or comment.line
  return Loc.get({
    name = path,
    cwd = root,
    range = { from = { comment.line, 0 }, to = { last, 0 }, kind = "line" },
  }, { kind = "line" })[1]
end

---Payload as sidekick text chunks, so each tool formats its own file reference
---(`sidekick.cli.context.location` tags the chunks and `tool:format` rewrites
---them). Without the location context, positions fall back to the plain form.
---@param all ReviewerComment[]
---@return sidekick.Text[]
local function payload_text(all)
  local root = store.root()
  local ok, Loc = pcall(require, "sidekick.cli.context.location")
  local clean = {}

  local lines = { { { header(all) } }, {} }
  for i, comment in ipairs(all) do
    local ref = { { string.format("%d. ", i) } }
    -- `mention` calls an internal sidekick module; a signature change there
    -- must degrade to the plain form, not raise out of `to_sidekick`.
    local loc
    if ok and root then
      local ok2, res = pcall(mention, Loc, comment, root, clean)
      loc = ok2 and res or nil
    end
    if loc then
      vim.list_extend(ref, loc)
    else
      table.insert(ref, { string.format("`%s`", location.format(comment)) })
    end
    table.insert(lines, ref)
    table.insert(lines, { { (comment.text:gsub("\n", " ")) } })
    table.insert(lines, {})
  end
  return lines
end

---Send every comment to sidekick.nvim, then remove them all.
function M.to_sidekick()
  local ok, sidekick = pcall(require, "sidekick.cli")
  if not ok then
    notify("sidekick.nvim not installed", vim.log.levels.ERROR)
    return
  end

  local all = store.get_all()
  if #all == 0 then
    notify("No comments to send", vim.log.levels.WARN)
    return
  end

  local sent, err = pcall(sidekick.send, { text = payload_text(all), name = opts.tool })
  if not sent then
    notify("Failed to send to sidekick: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  store.clear()
  marks.clear_all()
  notify(string.format("Sent %d comment(s) to sidekick", #all), vim.log.levels.INFO)
end

return M
