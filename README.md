# reviewer.nvim

A stripped-down, branch-scoped review layer for [codediff.nvim](https://github.com/esmuellert/codediff.nvim). Leave inline comments on a diff, then send them all to [sidekick.nvim](https://github.com/folke/sidekick.nvim) in one keystroke.

## Requirements

- Neovim >= 0.10
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim)
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) (only for sending comments)

## Install

With lazy.nvim:

```lua
{
  "ruicsh/reviewer.nvim",
  dependencies = {
    "esmuellert/codediff.nvim",
    { "folke/sidekick.nvim", optional = true },
  },
  event = "VeryLazy",
  opts = {},
}
```

Load the plugin before you open codediff (`VeryLazy` or `lazy = false`). The keys are buffer-local to the codediff panes, so they only work once the plugin is loaded. reviewer.nvim follows the current codediff tab: keys, marks, and comments apply to the active tab's session.

sidekick.nvim is optional and loaded on demand: it is only required when you send comments. The `optional = true` entry lets lazy.nvim load it when sending without force-loading it at startup.

## Options

```lua
opts = {
  sidekick = {
    -- sidekick tool that receives the comments; nil = sidekick's current tool
    tool = "copilot",
  },
  -- Keys are buffer-local to the codediff panes. Omit a key to keep its
  -- default; set it to false to disable that action.
  keys = {
    add_comment = "<localleader>a",
    file_comment = "<localleader>F",
    edit_comment = "<localleader>e",
    delete_comment = "<localleader>d",
    list_comments = "<localleader>c",
    next_comment = "]n",
    prev_comment = "[n",
    send_comments = "<localleader>S",
    close_review = "<localleader>q",
  },
}
```

## Keys (in a codediff diff)

| Key              | Option           | Action                                         |
| ---------------- | ---------------- | ---------------------------------------------- |
| `<localleader>a` | `add_comment`    | Add a comment at the cursor line, or on the visual selection |
| `<localleader>F` | `file_comment`   | Add or edit a file-level comment               |
| `<localleader>e` | `edit_comment`   | Edit the comment at the cursor                 |
| `<localleader>d` | `delete_comment` | Delete the comment at the cursor               |
| `<localleader>c` | `list_comments`  | List all comments and jump to one              |
| `]n`             | `next_comment`   | Next comment                                   |
| `[n`             | `prev_comment`   | Previous comment                               |
| `<localleader>S` | `send_comments`  | Send all comments to sidekick, then clear them |
| `<localleader>q` | `close_review`   | Clear comments and close the review tab        |

The diff buffers stay editable: no key the plugin sets shadows a normal Vim
editing key, so you can fix the file in the codediff pane.

`add_comment` works in visual mode too: select lines, then press
`<localleader>a` to comment on the whole range. Ranges are line-based, so a
character-wise selection comments every line it touches. The comment box sits
under the last selected line and the range is highlighted with `ReviewerRange`
(linked to `Visual` by default). Edit and delete find a range comment from any
line it covers.

`<localleader>` is resolved when the keys are installed, that is when a
codediff session opens, so set `vim.g.maplocalleader` before you open codediff.

Comment popup: `<C-s>` submits, `<Esc>` or `q` cancels.

## Storage

One JSON store per repository and branch, in `~/.local/share/nvim/reviewer/<repo>-<branch>.json`. Comments on one branch never show on another.

## Send format

`<localleader>S` sends a markdown list, one line per comment:

```
Code review comments on the current diff (`file:line` or `file:start-end`, `~` = old side).

1. `src/api.ts:23` - endpoint does not handle errors
2. `src/utils.ts:~10` - old implementation was cleaner
3. `src/api.ts` - whole file needs a pass
4. `src/db.ts:8-19` - this block duplicates the retry logic
```

A `~` before the line number marks the old (left) side of the diff. A bare path is a file-level comment. `start-end` is a multi-line comment, sent as one line. Multi-line comments are flattened to one line. After sending, all comments and their inline marks are removed.

## Tests

```bash
make test
```

Runs `tests/test_reviewer.lua` headless: store CRUD, branch-scoped paths, markdown shape, and the clear-on-success / keep-on-failure send behavior.

## License

MIT License - see [LICENSE](LICENSE)
