local M = {}

---Open the comment input popup. `<C-s>` submits; `<Esc>` or `q` cancels.
---@param initial_text? string
---@param callback fun(text: string|nil)
function M.open(initial_text, callback)
  local prev_win = vim.api.nvim_get_current_win()

  local width = 60
  local height = 8
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Comment (<C-s> to submit) ",
    title_pos = "center",
  })

  if initial_text and initial_text ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(initial_text, "\n"))
  end

  -- Set after opening so FileType autocmds (spell, ...) apply to this window.
  vim.bo[buf].filetype = "markdown"
  vim.cmd("startinsert")

  local function restore_focus()
    vim.defer_fn(function()
      if prev_win and vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
      vim.cmd("stopinsert")
    end, 10)
  end

  local function close_window()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    restore_focus()
  end

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text = table.concat(lines, "\n"):gsub("%s+$", "")
    close_window()
    if text ~= "" then
      callback(text)
    else
      callback(nil)
    end
  end

  local function cancel()
    close_window()
    callback(nil)
  end

  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<CR>", submit, { buffer = buf, noremap = true })
  vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, noremap = true })
  vim.keymap.set("n", "q", cancel, { buffer = buf, noremap = true })
end

return M
