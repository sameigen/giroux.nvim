# Regenerate the README demo GIF with vhs (charmbracelet/vhs):
#   cd giroux.nvim && vhs scripts/demo/demo.tape
# The demo itself is fully scripted + deterministic (scripts/demo/demo.lua):
# real roster/feed/statsheet over synthetic transcripts, no Claude/API/tmux.
Output "assets/demo.gif"
Output "assets/demo.mp4"
Require nvim

Set Shell "bash"
Set FontSize 20
Set Width 1280
Set Height 680
Set Padding 16
Set Margin 28
Set MarginFill "#1d2021"
Set BorderRadius 10
Set WindowBar Colorful
Set WindowBarSize 36
Set Theme "GruvboxDark"

# launch off-camera so startup flicker isn't recorded; the .lua self-drives
Hide
Type 'nvim --clean --cmd "set rtp+=." -c "luafile scripts/demo/demo.lua"'
Enter
Sleep 900ms
Show

# record through roster -> feed -> unfold -> answer -> stat sheet (demo :qa at ~16s)
Sleep 14500ms
