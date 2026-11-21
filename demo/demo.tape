# Records assets/demo.gif. Run `make demo` from the repository root.
#
# This records the real thing in the author's Neovim config: their theme, their
# keymaps (`<localleader>` is `,`), their sidekick pane, and opencode as the
# agent. It needs that config with reviewer, codediff, sidekick and opencode
# installed; it is not a portable sandbox. `demo/run.sh` puts this working tree
# first on the runtimepath, so the recording shows the local code.
Output assets/demo.gif
Set Shell bash
Set FontFamily "JetBrainsMono Nerd Font"
Set FontSize 15
Set Columns 168
Set Rows 40
Set TypingSpeed 75ms
Set CursorBlink false
Set Framerate 25
Set PlaybackSpeed 0.6
Set Theme "Catppuccin Mocha"

Hide
Type "bash demo/run.sh"
Enter
Sleep 9s
# Start the agent before recording. Missing this, sidekick has to ask which
# running opencode to use when the comments are sent, and that prompt would
# land in the middle of the take.
Ctrl+\
Sleep 2s
Enter
Sleep 14s
# Hide the pane again until the comments are sent.
Ctrl+w
Ctrl+\
Sleep 1s
Show

Sleep 400ms
Type ":CodeDiff"
Enter
Wait+Screen /Staged Changes/
Sleep 800ms

# Comment on a working-tree line.
Enter
Sleep 1200ms
Type "15G"
Sleep 400ms
Type ",a"
Sleep 700ms
Type "404s return HTML; this throws"
Sleep 300ms
Ctrl+S
Sleep 900ms

# Back to the explorer, into the staged file, comment on a range.
Ctrl+w
Type "h"
Sleep 400ms
Type "/db.ts"
Enter
Sleep 400ms
Enter
Sleep 1200ms
Type "11GV18G"
Sleep 400ms
Type ",a"
Sleep 700ms
Type "retries errors that can never succeed"
Sleep 300ms
Ctrl+S
Sleep 1s

# Send both, and the agent pane comes back with the payload in its prompt.
Type ",S"
Wait+Screen /Code review comments/
Sleep 3s
