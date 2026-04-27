#!/bin/sh
startdir=$1
pkgname=$2
recommends="${3:-}"


if [ -z "$startdir" ] || [ -z "$pkgname" ]; then
	echo "ERROR: missing argument!"
	echo "Please call $0 with \$startdir \$pkgname as arguments."
	exit 1
fi

srcdir="$startdir/src"
pkgdir="$startdir/pkg/$pkgname"

set -x
if [ -n "$recommends" ]; then
	mkdir -p "$pkgdir"/usr/share/flatpak/preinstall.d
	for r in $recommends; do
		flatpak_app="$(echo "$r" | cut -d';' -f2)"
		case "$flatpak_app" in
		flatpak:*) flatpak_app="$(echo "$flatpak_app" | cut -d':' -f2)" ;;
		*) continue ;;
		esac
		cat <<-EOF >> "$pkgdir/usr/share/flatpak/preinstall.d/$pkgname.preinstall"
			[Flatpak Preinstall $flatpak_app]
			Branch=stable
			IsRuntime=false
		EOF
	done
fi
