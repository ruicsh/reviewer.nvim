local M = {}

local data_dir = vim.fn.stdpath("data") .. "/reviewer"

---@class ReviewerComment
---@field id string
---@field file string repository-relative path
---@field line number 0 for a file-level comment
---@field side "old"|"new"
---@field text string

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
---@return ReviewerComment
function M.add(file, line, text, side)
  M.comments[file] = M.comments[file] or {}
  id_counter = id_counter + 1
  local comment = {
    id = string.format("c_%d_%d", os.time(), id_counter),
    file = file,
    line = line,
    side = side or "new",
    text = text,
  }
  table.insert(M.comments[file], comment)
  persist()
  return comment
end

---@param file string
---@param side? "old"|"new"
---@return ReviewerComment[]
function M.get_for_file(file, side)
  side = side or "new"
  local out = {}
  for _, comment in ipairs(M.comments[file] or {}) do
    if comment.line == 0 or (comment.side or "new") == side then
      table.insert(out, comment)
    end
  end
  return out
end

---@param file string
---@return ReviewerComment|nil
function M.get_file_comment(file)
  for _, comment in ipairs(M.comments[file] or {}) do
    if comment.line == 0 then
      return comment
    end
  end
  return nil
end

---@param file string
---@param line number
---@param side? "old"|"new"
---@return ReviewerComment|nil
function M.get_at_line(file, line, side)
  for _, comment in ipairs(M.comments[file] or {}) do
    if comment.line == line and (comment.side or "new") == (side or "new") then
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
