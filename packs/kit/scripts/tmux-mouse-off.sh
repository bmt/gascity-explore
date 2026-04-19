#!/bin/sh
# Disable tmux mouse mode — gastown enables it but it breaks terminal copy/paste.
tmux ${GC_TMUX_SOCKET:+-L "$GC_TMUX_SOCKET"} set-option -t "$1" mouse off 2>/dev/null || true
