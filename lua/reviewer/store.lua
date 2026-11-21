local M = {}

local data_dir = vim.fn.stdpath("data") .. "/reviewer"

---@class ReviewerComment
---@field id string
---@field file string repository-relative path
---@field line number start line; 0 for a file-level comment
---@field end_line? number last line of a multi-line comment; nil for a single line
---@field side "old"|"new"
---@field scope? string source-defined slice the comment belongs to (`staged`,
---  `unstaged`, ...). The same file and line can exist in two scopes with
---  different content, so scope is part of a comment's identity.
---@field text string
---@field excerpt? string text of the comment's first line when it was written;
---  nil for a file comment, an old-side line, and a scope with no file to read.
---  `send` compares it against the same slice before sending to catch a line
---  that moved, so the agent never applies a comment to different code.
---@field head? string short HEAD the comment was written against

---@type table<string, ReviewerComment[]>
M.comments = {}

local id_counter = 0
local loaded = false
local path_cache = nil ---@type string|false|nil
local repo_root = nil ---@type string|nil git root of the reviewed repository
local repo_branch = nil ---@type string|nil branch the store is currently keyed to

---@param args string[]
---@return string|nil
local function git_line(args)
  local out = vim.fn.systemlist(args)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

---@param root string
---@return string|nil
local function branch_of(root)
  return git_line({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" })
end

---@param str string
---@return string
local function hash(str)
  local h = 0
  for i = 1, #str do
    h = ((h * 31) + string.byte(str, i)) % 2147483647
  end
  return string.format("%x", h)
end

---@param path string
---@return string
local function strip_trailing(path)
  return (path:gsub("/+$", ""))
end

---Point the store at the reviewed repository. The codediff session knows its
---git root even when Neovim's cwd is elsewhere; without this the store would
---key off the cwd's repository and comments would not reload there.
---The branch is part of the store key, so a branch switch in the same repo
---resets the cache instead of leaking comments across branches.
---@param root string|nil
function M.set_repo(root)
  root = root and strip_trailing(root) or nil
  local branch = root and branch_of(root) or nil
  if root == repo_root and branch == repo_branch then
    return
  end
  repo_root = root
  repo_branch = branch
  path_cache = nil
  loaded = false
  M.comments = {}
  id_counter = 0
end

---Repository root the store is keyed to, resolved from the cwd when the caller
---never set one. `send` needs it to build editor file references.
---@return string|nil
function M.root()
  return repo_root or git_line({ "git", "rev-parse", "--show-toplevel" })
end

---Short HEAD of the reviewed repository, or nil outside one. Comments record it
---so the payload names the state the line numbers refer to.
---@return string|nil
function M.head()
  local root = M.root()
  if not root then
    return nil
  end
  return git_line({ "git", "-C", root, "rev-parse", "--short", "HEAD" })
end

---Branch the store is keyed to, or the current branch of the resolved root.
---@return string|nil
function M.branch()
  local root = M.root()
  if not root then
    return nil
  end
  if root == repo_root and repo_branch then
    return repo_branch
  end
  return branch_of(root)
end

---Scopes whose line text can be read back: the working tree, and the index when
---it is a diff's new side. A commit, revision range, conflict stage, and every
---old-side line name content that has no file at this path now, so they carry no
---excerpt and are never checked for drift.
---@param scope string|nil
---@return boolean
local function readable_scope(scope)
  return scope == nil or scope == "" or scope == "unstaged" or scope == "untracked" or scope == "staged"
end

---All lines of the slice `scope` refers to, or nil when it cannot be read: no
---repository or a file missing from that slice. Line endings are normalized, so
---a CRLF index and a CRLF working tree compare equal.
---@param file string
---@param scope? string
---@return string[]|nil
function M.lines(file, scope)
  local root = M.root()
  if not root then
    return nil
  end
  local out
  if scope == "staged" then
    out = vim.fn.systemlist({ "git", "-C", root, "show", ":" .. file })
    if vim.v.shell_error ~= 0 then
      return nil
    end
  else
    local handle = io.open(vim.fs.joinpath(root, file), "r")
    if not handle then
      return nil
    end
    out = {}
    for text_line in handle:lines() do
      table.insert(out, text_line)
    end
    handle:close()
  end
  for i, text_line in ipairs(out) do
    out[i] = text_line:gsub("\r$", "")
  end
  return out
end

---Text of `line` in the slice `scope` refers to, or nil when it cannot be read:
---a deleted file or a line past the end.
---@param file string
---@param line number
---@param scope? string
---@return string|nil
function M.line_text(file, line, scope)
  local lines = M.lines(file, scope)
  return lines and lines[line] or nil
end

---One store per (repository, branch): comments never leak across branches.
---@return string|nil
local function storage_path()
  if path_cache ~= nil then
    return path_cache or nil
  end
  local root = repo_root or git_line({ "git", "rev-parse", "--show-toplevel" })
  if not root then
    path_cache = false
    return nil
  end
  local branch = repo_branch
  if root ~= repo_root then
    branch = branch_of(root)
  end
  if not branch or branch == "" then
    path_cache = false
    return nil
  end
  pcall(vim.fn.mkdir, data_dir, "p")
  local safe_branch = branch:gsub("[^%w%-_]", "_")
  path_cache = string.format("%s/%s-%s.json", data_dir, hash(root), safe_branch)
  return path_cache
end

local function persist()
  local path = storage_path()
  if not path then
    return
  end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  -- Write to a temp file then rename so a crash mid-write cannot corrupt the store.
  local tmp = path .. ".tmp"
  local file = io.open(tmp, "w")
  if file then
    file:write(vim.fn.json_encode(M.comments))
    file:close()
    os.rename(tmp, path)
  end
end

function M.load()
  if loaded then
    return
  end
  loaded = true

  local path = storage_path()
  if not path or vim.fn.filereadable(path) == 0 then
    return
  end
  local file = io.open(path, "r")
  if not file then
    return
  end
  local content = file:read("*a")
  file:close()
  if not content or content == "" then
    return
  end

  local ok, data = pcall(vim.fn.json_decode, content)
  if not ok or type(data) ~= "table" then
    return
  end
  M.comments = data

  for _, list in pairs(M.comments) do
    for _, comment in ipairs(list) do
      local n = tonumber(comment.id and comment.id:match("_(%d+)$") or "")
      if n and n > id_counter then
        id_counter = n
      end
    end
  end
end

---@param file string
---@param line number
---@param text string
---@param side? "old"|"new"
---@param end_line? number last line of a multi-line comment; nil for a single line
---@param scope? string source-defined slice the comment belongs to
---@return ReviewerComment
function M.add(file, line, text, side, end_line, scope)
  M.comments[file] = M.comments[file] or {}
  id_counter = id_counter + 1
  local comment = {
    id = string.format("c_%d_%d", os.time(), id_counter),
    file = file,
    line = line,
    end_line = end_line and end_line > line and end_line or nil,
    side = side or "new",
    scope = scope,
    text = text,
  }
  -- Capture the anchor now: only a new-side line over the working tree or the
  -- index can be read back later, and only the first line of a range is needed
  -- to notice that the code moved.
  if line > 0 and comment.side == "new" and readable_scope(scope) then
    comment.excerpt = M.line_text(file, line, scope)
  end
  comment.head = M.head()
  table.insert(M.comments[file], comment)
  persist()
  return comment
end

---@param file string
---@param side? "old"|"new"
---@param scope? string source-defined slice; nil matches only unscoped comments
---@return ReviewerComment[]
function M.get_for_file(file, side, scope)
  side = side or "new"
  local out = {}
  for _, comment in ipairs(M.comments[file] or {}) do
    if (comment.line == 0 or (comment.side or "new") == side) and comment.scope == scope then
      table.insert(out, comment)
    end
  end
  return out
end

---@param file string
---@param scope? string source-defined slice; nil matches only unscoped comments
---@return ReviewerComment|nil
function M.get_file_comment(file, scope)
  for _, comment in ipairs(M.comments[file] or {}) do
    if comment.line == 0 and comment.scope == scope then
      return comment
    end
  end
  return nil
end

---Comment covering `line`, a multi-line comment included. That makes edit and
---delete work on any line of the range. `scope` is part of the identity: the
---same file line staged and unstaged are two different comments.
---@param file string
---@param line number
---@param side? "old"|"new"
---@param scope? string source-defined slice; nil matches only unscoped comments
---@return ReviewerComment|nil
function M.get_at_line(file, line, side, scope)
  for _, comment in ipairs(M.comments[file] or {}) do
    if
      (comment.side or "new") == (side or "new")
      and comment.scope == scope
      and line >= comment.line
      and line <= (comment.end_line or comment.line)
    then
      return comment
    end
  end
  return nil
end

---@param id string
---@param text string
---@return boolean
function M.update(id, text)
  for _, list in pairs(M.comments) do
    for _, comment in ipairs(list) do
      if comment.id == id then
        comment.text = text
        persist()
        return true
      end
    end
  end
  return false
end

---@param id string
---@return boolean
function M.delete(id)
  for file, list in pairs(M.comments) do
    for i, comment in ipairs(list) do
      if comment.id == id then
        table.remove(list, i)
        if #list == 0 then
          M.comments[file] = nil
        end
        persist()
        return true
      end
    end
  end
  return false
end

---@return ReviewerComment[]
function M.get_all()
  local all = {}
  for _, list in pairs(M.comments) do
    for _, comment in ipairs(list) do
      table.insert(all, comment)
    end
  end
  table.sort(all, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return all
end

---@return number
function M.count()
  local count = 0
  for _, list in pairs(M.comments) do
    count = count + #list
  end
  return count
end

function M.clear()
  local path = storage_path()
  if path then
    os.remove(path)
  end
  M.comments = {}
  id_counter = 0
  loaded = false
end

return M
