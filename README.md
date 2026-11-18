# reviewer.nvim

A stripped-down, branch-scoped review layer for [codediff.nvim](https://github.com/esmuellert/codediff.nvim) and [fugitive](https://github.com/tpope/vim-fugitive). Leave inline comments on a diff, then send them all to [sidekick.nvim](https://github.com/folke/sidekick.nvim) in one keystroke.

## Requirements

- Neovim >= 0.10
- [codediff.nvim](https://github.com/esmuellert/codediff.nvim) and/or [vim-fugitive](https://github.com/tpope/vim-fugitive)
- [sidekick.nvim](https://github.com/folke/sidekick.nvim) (only for sending comments)

## Install

With lazy.nvim:

```lua
{
  "ruicsh/reviewer.nvim",
  dependencies = {
    { "esmuellert/codediff.nvim", optional = true },
    { "tpope/vim-fugitive", optional = true },
    { "folke/sidekick.nvim", optional = true },
  },
  event = "VeryLazy",
  opts = {},
}
```

Load the plugin before you open a review surface (`VeryLazy` or `lazy = false`). The keys are buffer-local to the review buffers, so they only work once the plugin is loaded. reviewer.nvim follows the current codediff tab: keys, marks, and comments apply to the active tab's session.

sidekick.nvim is optional and loaded on demand: it is only required when you send comments. The `optional = true` entries let lazy.nvim load a plugin when it is used without force-loading it at startup.

## Review surfaces

| Surface                       | Positions come from                                |
| ----------------------------- | -------------------------------------------------- |
| codediff diff (both layouts)  | the codediff lifecycle: window → side, path → file |
| fugitive `:Git` status buffer | the buffer text: `@@` headers and sigils           |

A fugitive status buffer is a rendered view over git: file entries, section headings, and, once you expand a hunk with `>`, the real unified diff. A comment on a hunk line is stored as the _file_ line and side, derived from the `@@ -a,b +c,d @@` header, so it survives refreshes and `:Gwrite`. A comment on a file entry line is a file-level comment (line 0). A comment whose hunk is collapsed shows a count on the file's entry line until you expand it again.

The status buffer is rebuilt whenever the index changes. Marks are re-derived from the buffer text after every rebuild and whenever a hunk is expanded or collapsed, so they never point at a stale line.

Staged and unstaged are separate scopes: the same file line appears in both sections with different content, so a staged comment and an unstaged comment on the same line are two different comments. The scope is part of the sent location (`src/api.ts:12 (staged)`), so the agent knows to read the index rather than the working tree.

codediff gets the same treatment when its panes do not show the working tree. A comment on a staged file is `staged`; a comment on a commit from the history panel is `commit:abc1234`; a comparison of two revisions is `rev:abc1234..def5678`; a conflict side is `conflict:2`. A comment on a working-tree diff stays unscoped. Without this, a comment on a commit and a comment on the same line of the working tree would look identical in the payload and the agent would read the wrong bytes.

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

## Keys (in a codediff diff or a fugitive status buffer)

| Key              | Option           | Action                                                       |
| ---------------- | ---------------- | ------------------------------------------------------------ |
| `<localleader>a` | `add_comment`    | Add a comment at the cursor line, or on the visual selection |
| `<localleader>F` | `file_comment`   | Add or edit a file-level comment                             |
| `<localleader>e` | `edit_comment`   | Edit the comment at the cursor                               |
| `<localleader>d` | `delete_comment` | Delete the comment at the cursor                             |
| `<localleader>c` | `list_comments`  | List all comments and jump to one                            |
| `]n`             | `next_comment`   | Next comment                                                 |
| `[n`             | `prev_comment`   | Previous comment                                             |
| `<localleader>S` | `send_comments`  | Send all comments to sidekick, then clear them               |
| `<localleader>q` | `close_review`   | Clear comments and close the review tab                      |

The diff buffers stay editable: no key the plugin sets shadows a normal Vim
editing key, so you can fix the file in the codediff pane. In a fugitive status
buffer `close_review` clears the comments and detaches the keys; it does not
close the tab you opened it in.

`add_comment` works in visual mode too: select lines, then press
`<localleader>a` to comment on the whole range. Ranges are line-based, so a
character-wise selection comments every line it touches. In a fugitive hunk the
selection is mapped to file lines, and a selection that spans both sides of the
diff is refused rather than guessed. The comment box sits under the last
selected line and the range is highlighted with `ReviewerRange` (linked to
`Visual` by default). Edit and delete find a range comment from any line it
covers.

`<localleader>` is resolved when the keys are installed, that is when a
codediff session opens, so set `vim.g.maplocalleader` before you open codediff.

Comment popup: `<C-s>` submits, `<Esc>` or `q` cancels.

## Storage

One JSON store per repository and branch, in `~/.local/share/nvim/reviewer/<repo>-<branch>.json`. Comments on one branch never show on another. A codediff review and a fugitive status review of the same branch share the store file.

A comment's identity is `file`, `line`, `side`, and `scope`. `scope` names the slice of the repository the comment is about: the working tree (empty), `staged`, `unstaged`, or `untracked` in a fugitive status buffer, and `staged`, `conflict:2`, `commit:abc1234`, or `rev:abc1234..def5678` in codediff. Comments are therefore isolated by content, not by surface: a staged line commented in a fugitive status buffer and the same index line commented in codediff are one comment, while a working-tree comment and a commit comment on the same file line are two.

## Send format

`<localleader>S` sends a markdown list. Each comment is a reference line, then its text on the next line, then a blank line:

```
Code review comments (`~` = old side).

1. `src/api.ts:23`
endpoint does not handle errors

2. `src/utils.ts:~10`
old implementation was cleaner

3. `src/api.ts`
whole file needs a pass

4. `src/db.ts:8-19`
this block duplicates the retry logic

```

A `~` before the line number marks the old (left) side of the diff; the header only mentions it when such a comment is present. Inline diffs never produce one, since the original pane is not shown. A bare path is a file-level comment. `start-end` is a multi-line comment. Comment text is flattened to one line. After sending, all comments and their inline marks are removed.

The payload is built as sidekick text, so new-side comments are sent as that tool's own file reference (`@file#L10-20` for Claude, `@file :L10-L20` elsewhere) and expand to the file. Old-side comments keep the `file:~10` form, since a reference would point at the current file where that line no longer exists. `Unstaged` and `untracked` comments keep the reference too: their content is the working tree. `Staged` comments keep it while the file has no unstaged edits, so the index and the working tree agree at that line; once the working tree moves they keep the plain form. `conflict:N`, `commit:abc1234`, and `rev:a..b` always keep the plain form, because only it names the place the line lives.

## Tests

```bash
make test           # headless unit tests
make test-fugitive  # end-to-end against a real fugitive status buffer
```

`tests/test_reviewer.lua` runs headless: store CRUD, branch-scoped paths, scope isolation, fugitive position derivation, markdown shape, and the clear-on-success / keep-on-failure send behavior.

`tests/test_fugitive.lua` opens a real `:Git` buffer in a throwaway repo: it expands a hunk, checks that the cursor maps to the right file line and side, and that a comment's box follows the hunk through collapse, expand, and a status rebuild. It skips when vim-fugitive is not installed.

## License

MIT License - see [LICENSE](LICENSE)
