#!/bin/sh
# Functions provided for compatibility with old initramfs hooks.
# Whenever possible, please try to migrate hooks to nitro hook- service files.
# Not all old initramfs functions are implemented, only those required for the
# hooks in pmaports.

fail_halt_boot() {
	exit 111
}
