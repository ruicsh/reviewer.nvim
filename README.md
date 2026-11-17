# reviewer.nvim

A stripped-down, branch-scoped review layer for [codediff.nvim](https://github.com/esmuellert/codediff.nvim). Leave inline comments on a diff, then send them all to [sidekick.nvim](https://github.com/folke/sidekick.nvim) in one keystroke.

## Requirements

- Neovim >= 0.10
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) (only for `S`)

## Install

With lazy.nvim:

```lua
{
  "you/reviewer.nvim",
  dependencies = {
    "esmuellert/codediff.nvim",
  },
  event = "VeryLazy",
  opts = {},
}
```

Load the plugin before you open codediff (`VeryLazy` or `lazy = false`). The keys are buffer-local to the codediff panes, so they only work once the plugin is loaded. reviewer.nvim follows the current codediff tab: keys, marks, and comments apply to the active tab's session.

## Keys (in a codediff diff)

| Key         | Action                                         |
| ----------- | ---------------------------------------------- |
| `i`         | Add a comment at the cursor line               |
| `F`         | Add or edit a file-level comment               |
| `e`         | Edit the comment at the cursor                 |
| `d`         | Delete the comment at the cursor               |
| `c`         | List all comments and jump to one              |
| `]n` / `[n` | Next / previous comment                        |
| `S`         | Send all comments to sidekick, then clear them |
| `q`         | Clear comments and close the review tab        |

Comment popup: `<C-s>` submits, `<Esc>` or `q` cancels.

## Storage

One JSON store per repository and branch, in `~/.local/share/nvim/reviewer/<repo>-<branch>.json`. Comments on one branch never show on another.

## Send format

`S` sends a markdown list, one line per comment:

```
Code review comments on the current diff (`file:line`, `~` = old side).

1. `src/api.ts:23` - endpoint does not handle errors
2. `src/utils.ts:~10` - old implementation was cleaner
3. `src/api.ts` - whole file needs a pass
```

A `~` before the line number marks the old (left) side of the diff. A bare path is a file-level comment. Multi-line comments are flattened to one line. After sending, all comments and their inline marks are removed.

## Tests

```bash
make test
```

Runs `tests/test_reviewer.lua` headless: store CRUD, branch-scoped paths, markdown shape, and the clear-on-success / keep-on-failure send behavior.

## License

MIT License - see [LICENSE](LICENSE)
