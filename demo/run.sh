#!/usr/bin/env bash
# Start the demo session: the throwaway repo, in the user's own Neovim config.
#
# reviewer.nvim is prepended to the runtimepath so the recording shows the
# working tree instead of whatever the plugin manager has checked out.
#
# lazy.nvim resets the runtimepath during startup, which drops the early
# prepend. Prepend again on VimEnter, before lazy loads the plugin, so the
# working tree wins in both cases.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

cd "$here/work/acme-api"
exec nvim \
  --cmd "set rtp^=$root" \
  --cmd "lua vim.api.nvim_create_autocmd('VimEnter', { callback = function() vim.opt.rtp:prepend('$root') end })" \
  src/api.ts
