#!/bin/ash

user=$( getent passwd 10000 | cut -d: -f1 )
cmd=$( echo $0 | awk '{i=split($0,a,"/"); print a[i]}' )

case $cmd in
	KP_SLIDE_OPEN)
		su $user -c '/usr/bin/screenlock.sh unlock'
		/usr/bin/screenlock.sh kbd_backlight 31
		;;
	KP_SLIDE_CLOSE)
		/usr/bin/screenlock.sh kbd_backlight 0
		;;
	CAM_BTN_DWN)
		echo "Not implemented yet"
		;;
	CAM_BTN_UP)
		echo "Not implemented yet"
		;;
	CAM_FOCUS_DWN)
		echo "Not implemented yet"
		;;
	CAM_FOCUS_UP)
		echo "Not implemented yet"
		;;
	CAM_LID_CLOSE)
		echo "Not implemented yet"
		;;
	CAM_LID_OPEN)
		echo "Not implemented yet"
		;;
	SCRNLCK_DWN)
		echo "Not implemented yet"
		;;
	SCRNLCK_UP)
		echo "Not implemented yet"
		;;
	VIDEOOUT_INSERT)
		echo "Not implemented yet"
		;;
	VIDEOOUT_REMOVE)
		echo "Not implemented yet"
		;;
	*)
		echo "Unknown event"
		exit 1
		;;
esac
