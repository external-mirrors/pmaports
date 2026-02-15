#!/bin/sh

set_kbd_backlight() {
	for i in $(seq 1 6); do
		brightnessctl --quiet --device="*kb$i" s "$1"
	done
}

touch_state=$(xinput list-props "TSC2005 touchscreen" | grep "Device Enabled" | tr -d "\t" | cut -d ":" -f 2)

case "$touch_state" in
	0)
		xautolock -enable
		xinput enable "TSC2005 touchscreen"
		xset dpms force on
		set_kbd_backlight 25
		;;
	1)
		xautolock -disable
		xinput disable "TSC2005 touchscreen"
		xset dpms force off
		set_kbd_backlight 0
		;;
esac
