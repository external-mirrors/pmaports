#!/bin/bash
#
# This wrapper provides a mechanism for users to "uninstall"
# system apps in Phosh/GNOME UIs. Since we can't actually
# uninstall them we make a copy of the desktop file and add
# the Hidden property to disable them.
#

prompt="Are you sure you want to disable this system app?

It can be re-enabled by manually deleting the file

"

appid=""
pargs=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--uninstall)
			# Phosh passes an app ID like 'system/flatpak/flatpak/org.gnome.Calculator/*'
			appid="$(echo "$2" | rev | cut -d'/' -f2 | rev)"
			newpath="$HOME"/.local/share/applications/"$appid".desktop
			if grep -q "X-Duranium-Hidden=true" "$newpath" 2>/dev/null; then
				echo "App $appid already hidden."
				exit 0
			fi
			if [ -f /usr/share/applications/"$appid".desktop ]; then
				# Make sure the user didn't click by mistake and explain how to
				# re-enable the app
				if ! zenity --title="Disable system app" --question --text="$prompt <tt>$newpath</tt>"; then
					exit 1
				fi

				mkdir -p $HOME/.local/share/applications
				cp /usr/share/applications/"$appid".desktop $HOME/.local/share/applications/
				echo "Hidden=true" >> $newpath
				echo "X-Duranium-Hidden=true" >> $newpath
				echo "System app $appid has been hidden for user"
				exit 0
			fi
			pargs+=("$1", "$2"); shift 2
			;;
		-h|--help)
			echo "GNOME Software stub. This program can be used to hide"
			echo "system apps or uninstall flatpak apps, intended to be used"
			echo "by Phosh and other interfaces that use GNOME Software to"
			echo "uninstall apps."
			echo
			echo "Usage:"
			echo "gnome-software --uninstall APPID"
			exit 1
			;;
		*) pargs+=("$1"); shift;;
	esac
done

# If uninstalling a flatpak app do it directly
if [ -z "$appid" ]; then
	echo "GNOME Software is not installed, this is a compatibility wrapper"
	echo "for uninstalling apps, it only supports the --uninstall flag."
fi

if ! flatpak list --user --app | grep "$appid"; then
	zenity --title="Unknown application" --info --text="The app <tt>$appid</tt> can't be uninstalled."
	exit 1
fi

# Get the actual name of the app
app="$(flatpak info --user $appid | head -n2 | tail -1 | cut -d'-' -f1)"
[[ -n "$app" ]] || app="$appid"

# Ask the user to confirm
if ! zenity --question --title="Remove $app?" --text="Are you sure you want to uninstall $app?"; then
	exit 1;
fi

# Do the uninstall, logging to a temp file. If it fails show an error with the log
log=$(mktemp)
(
	flatpak uninstall --user --app --noninteractive --assumeyes $appid \
		|| zenity --title="Error uninstalling $app" --error --text="$(cat $log)"
) > $log

rm $log
