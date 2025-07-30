#!/bin/sh
# Additional functions that depend on initramfs-extra
# Functions are notated with the reason they're only in
# initramfs-extra

# udevd is too big
setup_udev() {
	if ! command -v udevd > /dev/null || ! command -v udevadm > /dev/null; then
		echo "ERROR: udev not found!"
		return
	fi

	# This is the same series of steps performed by the udev,
	# udev-trigger and udev-settle RC services. See also:
	# - https://git.alpinelinux.org/aports/tree/main/eudev/setup-udev
	# - https://git.alpinelinux.org/aports/tree/main/udev-init-scripts/APKBUILD
	udevd -d --resolve-names=never
	udevadm trigger --type=devices --action=add
	udevadm settle
}

# parted is too big
resize_root_partition() {
	local partition

	find_root_partition partition

	# Do not resize the installer partition
	if [ "$(blkid --label pmOS_install)" = "$partition" ]; then
		echo "Resize root partition: skipped (on-device installer)"
		return
	fi

	# Only resize the partition if it's inside the device-mapper, which means
	# that the partition is stored as a subpartition inside another one.
	# In this case we want to resize it to use all the unused space of the
	# external partition.
	if [ -z "${partition##"/dev/mapper/"*}" ] || [ -z "${partition##"/dev/dm-"*}" ]; then
		# Get physical device
		if [ -n "$SUBPARTITION_DEV" ]; then
			partition_dev="$SUBPARTITION_DEV"
		else
			partition_dev=$(dmsetup deps -o blkdevname "$partition" | \
				awk -F "[()]" '{print "/dev/"$2}')
		fi
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			# unmount subpartition, resize and remount it
			kpartx -d "$partition"
			parted -f -s "$partition_dev" resizepart 2 100%
			kpartx -afs "$partition_dev"
		else
			echo "Not resizing root partition ($partition): no free space left"
		fi

	# Resize the root partition (non-subpartitions). Usually we do not want
	# this, except for QEMU devices and non-android devices (e.g.
	# PinePhone). For them, it is fine to use the whole storage device and
	# so we pass PMOS_FORCE_PARTITION_RESIZE as kernel parameter.
	elif [ "$force_partition_resize" = "y" ]; then
		partition_dev="$(echo "$partition" | sed -E 's/p?2$//')"
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			parted -f -s "$partition_dev" resizepart 2 100%
			partprobe
		else
			echo "Not resizing root partition ($partition): no free space left"
		fi

	# Resize the root partition (non-subpartitions) on Chrome OS devices.
	# Match $deviceinfo_cgpt_kpart not being empty instead of cmdline
	# because it does not make sense here as all these devices use the same
	# partitioning methods. This also resizes third partition instead of
	# second, because these devices have an additional kernel partition
	# at the start.
	elif [ -n "$deviceinfo_cgpt_kpart" ]; then
		partition_dev="$(echo "$partition" | sed -E 's/p?3$//')"
		if has_unallocated_space "$partition_dev"; then
			echo "Resize root partition ($partition)"
			parted -f -s "$partition_dev" resizepart 3 100%
			partprobe
		else
			echo "Not resizing root partition ($partition): no free space left"
		fi

	else
		echo "Unable to resize root partition: failed to find qualifying partition"
	fi
}

unlock_root_partition() {
	command -v cryptsetup >/dev/null || return
	if cryptsetup isLuks "$PMOS_ROOT"; then
		# Make sure the splash doesn't interfere
		hide_splash
		tried=0
		until cryptsetup status root | grep -qwi active; do
			fde-unlock "$PMOS_ROOT" "$tried"
			tried=$((tried + 1))
		done
		PMOS_ROOT=/dev/mapper/root
		# Show again the loading splashscreen
		show_splash "Loading..."
	fi
}

# resize2fs and resize.f2fs are too big
resize_root_filesystem() {
	local partition

	find_root_partition partition
	touch /etc/mtab # see https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=673323
	check_filesystem "$partition"
	type="$(get_partition_type "$partition")"
	case "$type" in
		ext4)
			echo "Resize 'ext4' root filesystem ($partition)"
			modprobe ext4
			resize2fs "$partition"
			;;
		f2fs)
			echo "Resize 'f2fs' root filesystem ($partition)"
			modprobe f2fs
			resize.f2fs "$partition"
			;;
		btrfs)
			# Resize happens below after mount
			;;
		*)	echo "WARNING: Can not resize '$type' filesystem ($partition)." ;;
	esac
}

resize_filesystem_after_mount() {
	mountpoint="$1"
	type="$(get_mounted_filesystem_type "$mountpoint")"
	case "$type" in
		ext4)
			# ext4 can do online resize on recent kernels, but we still do it offline
			# for better compatibility with older kernels
			;;
		f2fs)
			# f2fs does not support online resizing
			;;
		btrfs)
			echo "Resize 'btrfs' filesystem ($mountpoint)"
			btrfs filesystem resize max "$mountpoint"
			;;
	esac
}

setup_efivarfs() {
	modprobe efivarfs || true
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
}

get_boot_device() {
	local efi_var part_uuid device
	efi_var="$(ls /sys/firmware/efi/efivars/LoaderDevicePartUUID-*)"

	# FIXME: this isn't a file?! -e (and -f, and so on) always fail on this path
	# if [ ! -e "$efi_var" ]; then
	# 	echo "ERROR: LoaderDevicePartUUID not found - not booted via EFI or efivarfs failed?"
	# 	return 1
	# fi

	# Read UUID, skip first 4 bytes (EFI attributes), convert to lowercase
	# https://docs.kernel.org/filesystems/efivarfs.html
	part_uuid=$(dd if="$efi_var" bs=1 skip=4 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')

	# Find device with matching PARTUUID
	device=$(blkid -t "PARTUUID=$part_uuid" -o device)
	if [ -z "$device" ]; then
		echo "ERROR: Could not find device with PARTUUID=$part_uuid"
		return 1
	fi

	# Get parent device by following symlinks in sysfs
	echo /dev/"$(basename "$(dirname "$(readlink /sys/class/block/"$(basename "$device")")")")"
}

factory_reset_requested() {
	local efi_var="/sys/firmware/efi/efivars/FactoryReset-8cf2644b-4b0b-428f-9387-6d876050dc67"
	[ -e "$efi_var" ] || return 1

	# Read value (skip 4-byte EFI attributes)
	local value
	value="$(dd if="$efi_var" bs=1 skip=4 2>/dev/null | tr -d '\0')"
	[ "$value" = "1" ] || [ "$value" = "yes" ] || [ "$value" = "true" ]
}

# Get first boot configuration values
get_firstboot_config() {
	# Make sure the splash doesn't interfere
	hide_splash
	for line in $(f0rmz); do
		key="${line%%=*}"
		value="${line#*=}"
		case "$key" in
		username)
			firstboot_username="$value"
			;;
		hostname)
			firstboot_hostname="$value"
			;;
		password)
			firstboot_password="$value"
			;;
		fde_password)
			firstboot_fde_password="$value"
			;;
		esac
	done

	[ -z "$firstboot_hostname" ] && firstboot_hostname="pmOS"
}

# Handle first boot scenario
handle_first_boot() {
	echo "No root partition found - performing first boot setup"
	show_splash "Preparing for first boot..."

	# Get configuration values from user
	get_firstboot_config

	echo "Creating partitions"
	show_splash "Preparing disk..."

	local boot_device
	boot_device="$(get_boot_device)"

	# Create runtime repart config based on user choices
	mkdir -p /run/repart.d
	local repart_args=""
	if [ -n "$firstboot_fde_password" ]; then
		# Copy base config and add encryption
		cp /usr/lib/repart.d/30-root.conf /run/repart.d/
		cat >> /run/repart.d/30-root.conf <<- EOF
			Encrypt=key-file
		EOF
		# Create key file for repart
		printf "$firstboot_fde_password" > /tmp/luks.key
		chmod 0600 /tmp/luks.key
		repart_args="--key-file=/tmp/luks.key"
	fi

	export TMPDIR=/tmp

	# Run systemd-repart to create partitions
	# NOTE: --root=/ because repart will assume root=/sysroot when running in the
	# initramfs
	if ! systemd-repart $repart_args --dry-run=no --root=/ "$boot_device"; then
		echo "ERROR: systemd-repart failed"
		fail_halt_boot
	fi

	# Find the newly created root partition
	local partition
	partition="$(find_root_on_boot_device "$boot_device")"
	if [ -z "$partition" ]; then
		echo "ERROR: Root partition not found after repart"
		fail_halt_boot
	fi

	# Unlock automatically if encrypted, since we already have the passphrase from
	# creating it
	if [ -n "$firstboot_fde_password" ] && [ -f /tmp/luks.key ]; then
		if ! cryptsetup open --key-file=/tmp/luks.key "$partition" root; then
		echo "ERROR: Failed to unlock encrypted root partition"
		fail_halt_boot
		fi
		partition="/dev/mapper/root"
	fi

	# Clean up key file
	rm -f /tmp/luks.key

	# Mount the root partition
	# shellcheck disable=SC2154
	echo "Mount root partition ($partition) to /sysroot (read-write) with options ${rootfsopts#,}"
	local type
	type="$(get_partition_type "$partition")"
	info "Detected $type filesystem"

	if ! { [ "$type" = "ext4" ] || [ "$type" = "f2fs" ] || [ "$type" = "btrfs" ]; } then
		echo "ERROR: Detected unsupported '$type' filesystem ($partition)."
		show_splash "ERROR: unsupported '$type' filesystem ($partition)\\nhttps://postmarketos.org/troubleshooting"
		fail_halt_boot
	fi

	if ! modprobe "$type"; then
		info "Unable to load module '$type' - assuming it's built-in"
	fi

	if ! mount -t auto "$partition" /sysroot; then
		echo "ERROR: Unable to mount root partition"
		fail_halt_boot
	fi

	# Mount /usr RO
	mkdir -p /sysroot/usr
	mount -t auto -o ro /dev/mapper/usr-verified /sysroot/usr

	# Manually copy user/group files from factory, we want to append to these
	mkdir -p /sysroot/etc
	for f in passwd group shadow; do
		cp -a /sysroot/usr/share/factory/etc/"$f" /sysroot/etc/
	done

	# Run systemd-firstboot
	echo "Setting up system configuration..."
	systemd-firstboot --root=/sysroot \
		--keymap=us \
		--locale=en_US.UTF-8 \
		--timezone="UTC" \
		--root-password-hashed="!" \
		--hostname="$firstboot_hostname"

	echo "Creating user account..."
	# TODO: There are other groups (e.g. 'seat') that the user should be in, in some
	# situations (running specific UIs, and so on). Hardcoding them here isn't great...
	# Note: This creates a locked account
	systemd-sysusers --root=/sysroot --inline \
		"u $firstboot_username - \"Default User\" /home/$firstboot_username /bin/sh" \
		"m $firstboot_username audio" \
		"m $firstboot_username input" \
		"m $firstboot_username netdev" \
		"m $firstboot_username plugdev" \
		"m $firstboot_username video" \
		"m $firstboot_username wheel"

	# Then update user to set password
	# TODO: Is there a better way? sysusers doesn't seem to support this...
	echo "$firstboot_username:$firstboot_password" | chpasswd -R /sysroot

	# Save real user's username for future generators
	echo "$firstboot_username" > /sysroot/etc/default_user

	# Create tmpfiles.d fragment for home directory
	mkdir -p /sysroot/etc/tmpfiles.d
	cat > /sysroot/etc/tmpfiles.d/user-home.conf <<- EOF
		# Create home directory for $firstboot_username
		d /home/$firstboot_username 0755 $firstboot_username $firstboot_username - -
	EOF

	ln -s /usr/bin /sysroot/bin
	ln -s /usr/sbin /sysroot/sbin
	ln -s /usr/lib /sysroot/lib

	echo "First boot setup complete"
}

# Function to extract UUIDs from usrhash
extract_uuids_from_usrhash() {
	local hash="$1"
	local usr_uuid_raw
	local verity_uuid_raw
	local usr_uuid
	local verity_uuid

	# Validate input length (should be 64 hex characters = 256 bits)
	if [ ${#hash} -ne 64 ]; then
	echo "Error: usrhash should be 64 hex characters (256 bits)" >&2
	return 1
	fi

	# Extract first 128 bits (32 hex chars) for /usr partition UUID
	usr_uuid_raw="$(echo "$hash" | cut -c1-32)"

	# Extract last 128 bits (32 hex chars) for verity partition UUID
	verity_uuid_raw="$(echo "$hash" | cut -c33-64)"

	# NOTE: parts are extracted below one at a time to help with code
	# readability

	# Format /usr UUID as proper UUID (xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
	usr_part1="$(echo "$usr_uuid_raw" | cut -c1-8)"
	usr_part2="$(echo "$usr_uuid_raw" | cut -c9-12)"
	usr_part3="$(echo "$usr_uuid_raw" | cut -c13-16)"
	usr_part4="$(echo "$usr_uuid_raw" | cut -c17-20)"
	usr_part5="$(echo "$usr_uuid_raw" | cut -c21-32)"
	usr_uuid="${usr_part1}-${usr_part2}-${usr_part3}-${usr_part4}-${usr_part5}"

	# Format verity UUID as proper UUID
	verity_part1="$(echo "$verity_uuid_raw" | cut -c1-8)"
	verity_part2="$(echo "$verity_uuid_raw" | cut -c9-12)"
	verity_part3="$(echo "$verity_uuid_raw" | cut -c13-16)"
	verity_part4="$(echo "$verity_uuid_raw" | cut -c17-20)"
	verity_part5="$(echo "$verity_uuid_raw" | cut -c21-32)"
	verity_uuid="${verity_part1}-${verity_part2}-${verity_part3}-${verity_part4}-${verity_part5}"

	echo "USR_PARTITION_UUID=$usr_uuid"
	echo "VERITY_PARTITION_UUID=$verity_uuid"
	echo "VERITY_ROOT_HASH=$hash"
}

# Resolve the given partuuid to a block device
find_partuuid() {
	local uuid="$1"
	local path=/dev/disk/by-partuuid/"$uuid"

	if [ ! -L "$path" ]; then
		echo ""
		return
	fi
	echo "$(readlink -f "$path")"
}

# Get the appropriate root GPT type for the booted arch
get_root_partition_uuid() {
	# shellcheck disable=SC2154
	case "$deviceinfo_arch" in
	x86_64) echo "4f68bce3-e8cd-4db1-96e7-fbcaf984b709" ;;
	x86) echo "44479540-f297-41b2-9af7-d131d5f0458a" ;;
	aarch64) echo "b921b045-1df0-41c3-af44-4c6f280d3fae" ;;
	armv7|armhf) echo "69dad710-2ce4-4e3c-b16c-21a1d49abed3" ;;
	riscv64) echo "72ec70a6-cf74-40e6-bd49-4bda08e8f224" ;;
	*) echo "" ;;  # Unsupported arch
	esac
}

# Use GPT type to find the appropriate root partition on the device containing
# the booted ESP
find_root_on_boot_device() {
	local boot_device="$1"
	local root_uuid
	root_uuid="$(get_root_partition_uuid)"

	[ -z "$root_uuid" ] && return 1

	# Check each partition on the boot device
	# FIXME: this only looks at the first few partitions, and is kind of a hack,
	# and may need to be more dynamic (using sgdisk or something?)
	for part_num in $(seq 2 10); do
	partition="${boot_device}${part_num}"
	[ -e "$partition" ] || partition="${boot_device}p${part_num}"
	[ -e "$partition" ] || continue

	# Check GPT partition type UUID
	if blkid -p -s PART_ENTRY_TYPE "$partition" | grep -qi "$root_uuid"; then
	echo "$partition"
	return
	fi
	done
}

mount_and_check_populated() {
	local partition="$1"
	[ -z "$partition" ] && return 1

	# Mount the root partition
	# shellcheck disable=SC2154
	echo "Mount root partition ($partition) to /sysroot (read-write) with options ${rootfsopts#,}"
	local type
	type="$(get_partition_type "$partition")"
	info "Detected $type filesystem"

	if ! { [ "$type" = "ext4" ] || [ "$type" = "f2fs" ] || [ "$type" = "btrfs" ]; } then
		echo "ERROR: Detected unsupported '$type' filesystem ($partition)."
		show_splash "ERROR: unsupported '$type' filesystem ($partition)\\nhttps://postmarketos.org/troubleshooting"
		fail_halt_boot
	fi

	if ! modprobe "$type"; then
		info "Unable to load module '$type' - assuming it's built-in"
	fi

	# Try to mount the partition
	if mount -t auto "$partition" /sysroot 2>/dev/null; then
	# Check if populated (has /etc/os-release)
	if [ -L /sysroot/etc/os-release ]; then
	return 0  # Success - leave mounted
	else
	umount /sysroot
	return 1  # Not populated
	fi
	fi

	return 1  # Failed to mount
}

handle_immutable_boot() {
	local usrhash="$1"

	setup_efivarfs

	# Make sure loop is loaded, else repart falls back to using a file and it's...
	# buggy.
	modprobe loop

	# Set up dm-verity for /usr first
	eval "$(extract_uuids_from_usrhash "$usrhash")"
	local usr_device verity_device
	usr_device="$(find_partuuid "$USR_PARTITION_UUID")"
	verity_device="$(find_partuuid "$VERITY_PARTITION_UUID")"

	if [ -z "$usr_device" ] || [ -z "$verity_device" ]; then
	echo "ERROR: Unable to locate /usr partitions"
	fail_halt_boot
	fi

	if ! veritysetup open "$usr_device" usr-verified "$verity_device" "$VERITY_ROOT_HASH"; then
	echo "ERROR: Unable to create verity mapping for /usr"
	fail_halt_boot
	fi

	local boot_device
	boot_device="$(get_boot_device)"

	# Handle factory reset request
	if factory_reset_requested; then
	echo "Factory reset requested - deleting partitions"
	boot_device="$(get_boot_device)"
		# NOTE: --root=/ because repart will assume root=/sysroot when running in the
		# initramfs
	if ! systemd-repart --dry-run=no --root=/ "$boot_device"; then
	echo "ERROR: Factory reset systemd-repart failed"
	fail_halt_boot
	fi

		# Now delete the root partition, so that it can be recreated later in the
		# first boot logic with optional encryption. If this isn't done, systemd-repart
		# will *not* enable encryption since the partition already exists.
		local root_part_num
		root_part_num="$(blkid -p -s PART_ENTRY_NUMBER -o value "$(find_root_on_boot_device "$boot_device")")"
	if ! parted -s "$boot_device" rm "$root_part_num"; then
		echo "ERROR: Unable to remove empty root partition"
		fail_halt_boot
	fi
	else  # Not factory resetting...
		# Find root partition on boot device
		PMOS_ROOT="$(find_root_on_boot_device "$boot_device")"
	fi

	unlock_root_partition

	# Check if root is populated
	if [ -n "$PMOS_ROOT" ] && mount_and_check_populated "$PMOS_ROOT"; then
		# Normal boot - root already mounted
		# Mount /usr RO
		mount -t auto -o ro /dev/mapper/usr-verified /sysroot/usr
	else
		# First boot or factory reset
		handle_first_boot
	fi
}
