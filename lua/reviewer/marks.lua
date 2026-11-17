local M = {}

local store = require("reviewer.store")

local ns_id = vim.api.nvim_create_namespace("reviewer")

---@param text string
---@return table[] virt_lines
local function build_box(text)
  local lines = vim.split(text, "\n")
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(width, 20)

  local virt_lines = {}
  table.insert(virt_lines, { { "╭" .. string.rep("─", width + 2) .. "╮", "ReviewerComment" } })
  for _, line in ipairs(lines) do
    local padding = width - vim.fn.strdisplaywidth(line)
    table.insert(virt_lines, { { "│ " .. line .. string.rep(" ", padding) .. " │", "ReviewerComment" } })
  end
  table.insert(virt_lines, { { "╰" .. string.rep("─", width + 2) .. "╯", "ReviewerComment" } })
  return virt_lines
end

---@param bufnr number
---@param side "old"|"new"
---@param file string
function M.render_for_buffer(bufnr, side, file)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not file then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, comment in ipairs(store.get_for_file(file, side)) do
    local virt_lines = build_box(comment.text)

    if comment.line == 0 then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, 0, 0, {
        sign_text = "●",
        sign_hl_group = "ReviewerComment",
        virt_lines = virt_lines,
        virt_lines_above = true,
      })
      -- Reveal virt_lines above row 0 when the window is scrolled to the top.
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
          vim.api.nvim_win_call(win, function()
            local view = vim.fn.winsaveview()
            if view.topline <= 1 then
              view.topfill = #virt_lines
              vim.fn.winrestview(view)
            end
          end)
        end
      end
    else
      local row = comment.line - 1
      local last_row = math.min((comment.end_line or comment.line) - 1, line_count - 1)
      if row >= 0 and row < line_count and last_row >= row then
        if last_row > row then
          -- Cover the whole range, last line included: an end row of 0 with
          -- hl_eol stops at the start of `end_row`, and `line_count` is the
          -- largest accepted value.
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, row, 0, {
            end_row = math.min(last_row + 1, line_count),
            end_col = 0,
            hl_group = "ReviewerRange",
            hl_eol = true,
          })
        end
        -- Sign on the first line, comment box under the last one.
        local sign = { sign_text = "●", sign_hl_group = "ReviewerComment" }
        if last_row == row then
          sign.virt_lines = virt_lines
          sign.virt_lines_above = false
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, row, 0, sign)
        else
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, row, 0, sign)
          pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, last_row, 0, {
            virt_lines = virt_lines,
            virt_lines_above = false,
          })
        end
      end
    end
  end
end

function M.refresh()
  local hooks = require("reviewer.hooks")
  local orig_buf, mod_buf = hooks.get_buffers()
  local orig_path, mod_path = hooks.get_paths()
  if orig_buf then
    M.render_for_buffer(orig_buf, "old", orig_path)
  end
  if mod_buf then
    M.render_for_buffer(mod_buf, "new", mod_path)
  end
end

function M.clear_all()
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
    end
  end
end

return M
