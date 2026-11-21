#!/usr/bin/env bash
# Start the demo session: the throwaway repo, in the user's own Neovim config.
#
# reviewer.nvim is prepended to the runtimepath so the recording shows the
# working tree instead of whatever the plugin manager has checked out.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

cd "$here/work/acme-api"
exec nvim --cmd "set rtp^=$root" src/api.ts
