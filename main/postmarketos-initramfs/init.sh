#!/bin/busybox ash

# This is set during packaging and is used when triaging bug reports
INITRAMFS_PKG_VERSION="<<INITRAMFS_PKG_VERSION>>"
echo "Nura-rd: Initramfs version: $INITRAMFS_PKG_VERSION"

# TODO: Bit neater startup?
exec /usr/sbin/nitro /usr/share/initramfs/svc
