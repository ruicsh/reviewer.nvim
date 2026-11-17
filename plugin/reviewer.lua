if vim.g.loaded_reviewer then
  return
end
vim.g.loaded_reviewer = true

require("reviewer").setup()
