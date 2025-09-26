#!/bin/sh
# shellcheck disable=SC1091

# This is the "real" init.sh script, it's either jumped to immediately
# from init.sh, or loaded from initramfs-extra on the boot partition
# on space constrained devices with deviceinfo_create_initfs_extra="true".

# The set -a in init.sh only exports variables, not functions
. /init_functions.sh
. /init_functions_2nd.sh

# Run udev early, before splash, to make sure any relevant display drivers are
# loaded in time
setup_udev

setup_usb_network
start_unudhcpd

# Splash is already running if we're loaded from initramfs-extra
if [ "$deviceinfo_create_initfs_extra" != "true" ] && [ "$IN_CI" = "false" ]; then
	setup_framebuffer
	show_splash "Loading..."
fi

setup_dynamic_partitions "${deviceinfo_super_partitions:=}"

run_hooks /hooks

if [ "$IN_CI" = "true" ]; then
	echo "PMOS: CI tests done, disabling console and looping forever"
	dmesg -n 1
	fail_halt_boot
fi

if [ "$debug_shell" = "y" ]; then
	debug_shell
fi

check_keys

# If running from initramfs-extra this will be a no-op since it was
# called before to mount the boot partition
#
# FIXME: At some point we'll probably need to support subpartitions with
# immutable boot, but for now disabling the subpartition check saves 10 seconds
# from boot
if ! is_immutable_boot; then
	mount_subpartitions
fi

run_hooks /hooks-extra

if is_immutable_boot; then
	handle_immutable_boot
else
	wait_root_partition
	delete_old_install_partition
	resize_root_partition
	unlock_root_partition
	resize_root_filesystem
	mount_root_partition
	resize_filesystem_after_mount /sysroot

	# Mount boot partition into sysroot if needed since some
	# old installations don't have a proper /etc/fstab file. See #2800
	if [ -z "$(cat /sysroot/etc/fstab | grep -v "#" | tr -d '[:space:]')" ]; then
		wait_boot_partition
		mount_boot_partition /sysroot/boot "rw"
	fi
fi

init="/sbin/init"
setup_bootchart2

# Switch root
run_hooks /hooks-cleanup

echo "Switching root"

# Restore stdout and stderr to their original values if they
# were stashed
if [ -e "/proc/1/fd/3" ]; then
	exec 1>&3 2>&4
elif [ "$debug_shell" != "y" ]; then
	echo "$LOG_PREFIX Disabling console output again (use 'pmos.debug-shell' to keep it enabled)"
	exec >/dev/null 2>&1
fi

# Make it clear that we're at the end of the initramfs
show_splash "Starting..."

# Re-enable kmsg ratelimiting (might have been disabled for logging)
echo ratelimit > /proc/sys/kernel/printk_devkmsg

killall udevd syslogd 2>/dev/null

# Kill any getty shells that might be running
for pid in $(pidof sh); do
	if ! [ "$pid" = "1" ]; then
		kill -9 "$pid"
	fi
done

# cleanup after ourselves
# switch_root does a mount --move , keeping stale filesystems like devtmpfs
# with /dev/log in there.
rm /dev/log 2>/dev/null || true


# shellcheck disable=SC2093
exec switch_root /sysroot "$init"

echo "$LOG_PREFIX ERROR: switch_root failed!" > /dev/kmsg
echo "$LOG_PREFIX Looping forever. Install and use the debug-shell hook to debug this." > /dev/kmsg
echo "$LOG_PREFIX For more information, see <https://postmarketos.org/debug-shell>" > /dev/kmsg
fail_halt_boot
