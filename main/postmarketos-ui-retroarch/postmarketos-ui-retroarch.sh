#!/bin/sh

# On systemd, this is implicitly set, so no-op.
if [ -z "$XDG_RUNTIME_DIR" ]; then
	XDG_RUNTIME_DIR=$(mkrundir)
	export XDG_RUNTIME_DIR
fi

gamescope --force-windows-fullscreen retroarch && loginctl poweroff
