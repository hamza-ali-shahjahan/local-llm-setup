# Demo recording for local-llm-setup.
# Render with:  vhs assets/demo.tape   (run from the repo root)
# Produces:     assets/demo.gif
#
# It runs a real --dry-run, so nothing is installed or downloaded — the GIF
# shows the hardware auto-detection and the sized plan, stopping at the prompt.

Output assets/demo.gif

Set Shell "bash"
Set FontSize 17
Set Width 860
Set Height 440
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 55ms

# Hide the prompt setup so the recording starts clean.
Hide
Type "export PS1='$ '" Enter
Type "clear" Enter
Show

Sleep 800ms
Type "./local-llm-setup.sh --dry-run"
Sleep 700ms
Enter
Sleep 4500ms
