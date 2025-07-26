#!/bin/busybox ash
# This file will be in /init_functions_immutable.sh inside the initramfs.
# shellcheck disable=SC3043

USR_PARTITION=""
VERITY_PARTITION=""
BOOT_DEVICE=""

# Mount EFI vars
setup_efivarfs() {
	if mountpoint -q /sys/firmware/efi/efivars; then
		info "efivars already mounted"
		return 0
	fi
	info "Mounting efivars"
	modprobe efivarfs || true
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars || true
}

# Extract the ESP *partition* UUID from EFI's LoaderDevicePart variable
# Uses: (none)
# Sets: uuid variable via output parameters
# $1: variable name to store ESP partition UUID
get_esp_partition_uuid_from_efi() {
	local result="$1"
	local efi_var uuid

	setup_efivarfs
	efi_var="$(ls /sys/firmware/efi/efivars/LoaderDevicePartUUID-*)"

	if [ ! -e "$efi_var" ]; then
		echo "ERROR: LoaderDevicePartUUID not found - not booted via EFI or efivarfs failed?"
		return 1
	fi

	# Read UUID, skip first 4 bytes (EFI attributes), convert to lowercase
	# https://docs.kernel.org/filesystems/efivarfs.html
	uuid=$(dd if="$efi_var" bs=1 skip=4 2>/dev/null | tr -d '\0' | tr '[:upper:]' '[:lower:]')
	info "Found ESP UUID: $uuid"

	# Set the result
	if [ -n "$result" ]; then eval "$result=\"$uuid\""; fi
}

# Get boot device from EFI LoaderDevicePartUUID variable
# Sets: BOOT_DEVICE
# Returns: 1 if EFI variable not found or invalid, 0 on success
find_boot_device() {
	local part_uuid device

	# If we have subpartitions, the boot device is the partition containing them
	if [ -n "$SUBPARTITION_DEV" ]; then
		BOOT_DEVICE="$SUBPARTITION_DEV"
		info "Using subpartition container as boot device: $BOOT_DEVICE"
		return 0
	fi

	if ! get_esp_partition_uuid_from_efi part_uuid; then
		return 1
	fi

	info "Searching for boot device with uuid: $part_uuid"

	show_splash "Waiting for boot device..."

	for _ in $(seq 1 30); do
		# Find device with matching PARTUUID
		device="$(readlink -f "/dev/disk/by-partuuid/$part_uuid")"
		if [ -b "$device" ]; then
			device="$(basename "$device")"
			parent_path="/sys/class/block/$device/.."
			info "Searching parent path: $parent_path"
			if [ -d "$parent_path" ]; then
				BOOT_DEVICE="/dev/$(basename "$(readlink -f "$parent_path")")"
				if [ -n "$BOOT_DEVICE" ] && [ "$BOOT_DEVICE" != "/dev/" ]; then
					info "Found boot device: $BOOT_DEVICE"
					return 0
				fi
			fi
		fi

		info "Boot device not found yet, trying again in 1 second..."
		sleep 1
	done

	echo "ERROR: boot device not found after 30 seconds"
	return 1
}

factory_reset_requested() {
	# TODO: In systemd 258 this variable will be `FactoryResetRequest`
	local efi_var="/sys/firmware/efi/efivars/FactoryReset-8cf2644b-4b0b-428f-9387-6d876050dc67"
	[ -e "$efi_var" ] || return

	# Read value (skip 4-byte EFI attributes)
	local value
	value="$(dd if="$efi_var" bs=1 skip=4 2>/dev/null | tr -d '\0')"
	info "Factory reset EFI var value: $value"
	[ "$value" = "1" ] || [ "$value" = "yes" ] || [ "$value" = "true" ]
}

# Run systemd-repart to initialize A/B partition layout on GPT-partitioned block
# devices, creating B-slot partitions sized to match A-slot
# NOTE: This does *not* support subpartitioned devices!
# $1: optional path to luks keyfile for encrypting partition
# Uses: USR_PARTITION, VERITY_PARTITION
# Sets: (none)
# Returns: 1 on error, else 0
run_repart() {
	local keyfile="$1"

	# HACK: Symlink os-release --> initrd-release. Ideally this would be handled by
	# mkinitfs config, but there's a bug preventing that from working correctly,
	# so for now let's do this. Using -f because if the bug is fixed, we don't want
	# the initramfs init to fail if the script hasn't been updated yet to remove
	# this hack.
	# https://gitlab.postmarketos.org/postmarketOS/postmarketos-mkinitfs/-/issues/50
	#
	# Repart will not enable factory reset logic unless this file exists, to prove
	# it's running in the initramfs.
	ln -sf /usr/lib/os-release /etc/initrd-release

	export TMPDIR=/tmp
	# Disable discarding blocks while formatting, otherwise it can take like 10
	# minutes to format a 1TB partition with BTRFS on a fast NVMe!
	export SYSTEMD_REPART_MKFS_OPTIONS_BTRFS="--nodiscard"

	# Calculate slot B partition sizes for repart. Look at their slot A counterparts
	# to get the size that they should be. This is better than hardcoding some
	# totally made up size (e.g. 20GB) and hoping it's enough for an update to it.
	mkdir -p /run/repart.d/22-usr.conf.d
	mkdir -p /run/repart.d/21-usr-verity.conf.d
	mkdir -p /run/repart.d/12-usr.conf.d
	mkdir -p /run/repart.d/11-usr-verity.conf.d

	# Need usr partitions for size calculations
	wait_partition "usr" "find_usr_partition"
	wait_partition "verity" "find_usr_verity_partition"

	# Get A-slot sizes
	usr_size="$(blockdev --getsize64 "$USR_PARTITION")"
	verity_size="$(blockdev --getsize64 "$VERITY_PARTITION")"

	info "Using usr partition size: $usr_size"
	info "Using usr verity partition size: $verity_size"

	# Create size override drop-ins
	# Note: This sets limits for existing partitions too because repart likes to
	# try and grow existing A-slot partitions if the B-slot partitions don't exist
	# when repart runs.
	cat > /run/repart.d/22-usr.conf.d/10-runtime-size.conf <<-EOF
	[Partition]
	SizeMinBytes=${usr_size}
	SizeMaxBytes=${usr_size}
	EOF
	cat > /run/repart.d/12-usr.conf.d/10-runtime-size.conf <<-EOF
	[Partition]
	SizeMinBytes=${usr_size}
	SizeMaxBytes=${usr_size}
	EOF
	cat > /run/repart.d/21-usr-verity.conf.d/10-runtime-size.conf <<-EOF
	[Partition]
	SizeMinBytes=${verity_size}
	SizeMaxBytes=${verity_size}
	EOF
	cat > /run/repart.d/11-usr-verity.conf.d/10-runtime-size.conf <<-EOF
	[Partition]
	SizeMinBytes=${verity_size}
	SizeMaxBytes=${verity_size}
	EOF

	# NOTE: when repart detects it is running in the initramfs, it will assume
	# root=sysroot and read configuration from there. Since /sysroot is not mounted
	# yet and the filesystem that backs it hasn't been created/populated yet (that's
	# the point of repart), we need to tell repart to use the repart.d config in the
	# initramfs by specifying root=/
	repart_args="--no-pager --dry-run=no --root=/ "
	if [ -n "$keyfile" ]; then
		repart_args="$repart_args --key-file=$keyfile"
	fi
	info "Running systemd-repart with args: $repart_args"

	local target_device="$BOOT_DEVICE"
	[ -n "$SUBPARTITION_LOOP" ] && target_device="$SUBPARTITION_LOOP"

	# shellcheck disable=SC2086
	if ! systemd-repart $repart_args "$target_device"; then
		return 1
	fi

	local probe_target="$BOOT_DEVICE"
	if [ -n "$SUBPARTITION_LOOP" ]; then
		probe_target="$SUBPARTITION_LOOP"
	fi
	partprobe "$probe_target"
	udevadm settle --timeout=30
}

# Show an interactive UI to let the user configure the system and report the
# values
# Uses: (none)
# Sets: firstboot_username, firstboot_hostname, firstboot_password,
#       firstboot_fde_password
# Returns: (none)
get_firstboot_config() {
	# Make sure the splash doesn't interfere
	hide_splash

	local output
	output=$(f0rmz)
	if [ -n "$output" ] && echo "$output" | grep -q "username="; then
		while IFS= read -r line; do
			key="${line%%=*}"
			value="${line#*=}"
			case "$key" in
			username)
				firstboot_username="$value" ;;
			hostname)
				firstboot_hostname="$value" ;;
			password)
				firstboot_password="$value" ;;
			fde_password)
				firstboot_fde_password="$value" ;;
			esac
		done <<-EOF
		$output
		EOF
	else
		echo "ERROR: running f0rmz configuration UI failed!"
		fail_halt_boot
	fi

	[ -z "$firstboot_hostname" ] && firstboot_hostname="pmOS"
}

# Create dm-verity mapping for /usr partition
# Uses: USR_PARTITION, VERITY_PARTITION, usrhash
# Sets: (none)
# $1: variable name to store verity device path
# Returns: 1 if verity setup fails, 0 on success
setup_verity_mapping() {
	local result="$1"
	local verity_device="/dev/mapper/usr-verified"

	# Wait for both partitions to be available
	wait_partition "usr" "find_usr_partition"
	wait_partition "verity" "find_usr_verity_partition"

	# Set up dm-verity mapping
	# shellcheck disable=SC2154
	if ! veritysetup open "$USR_PARTITION" usr-verified "$VERITY_PARTITION" "$usrhash"; then
		echo "ERROR: Unable to create verity mapping for /usr"
		return 1
	fi

	# Set the result
	if [ -n "$result" ]; then eval "$result=\"$verity_device\""; fi
}

# Mount verity-protected /usr partition
# Uses: USR_PARTITION, VERITY_PARTITION, usrhash
# Sets: (none)
# Returns: 1 if verity setup or mount fails, 0 on success
mount_usr_verified() {
	local device_path

	# Set up dm-verity mapping
	if ! setup_verity_mapping device_path; then
		return 1
	fi

	info "Using verified usr partition mapped at: $device_path"

	modprobe erofs || true

	# Mount /usr read-only
	mkdir -p /sysroot/usr
	if ! mount -t erofs -o ro "$device_path" /sysroot/usr; then
		echo "ERROR: Unable to mount verified /usr"
		return 1
	fi

	return 0
}

# Handle systemd-repart for first boot/factory reset
# Uses: BOOT_DEVICE, USR_PARTITION, VERITY_PARTITION, firstboot_fde_password
# Sets: PMOS_ROOT (after partition creation)
# Returns: 1 if repart fails, 0 on success
setup_first_boot_partitions() {
	local disk_mb usr_mb verity_mb ab_needed_mb required_mb min_root_mb
	local root_part_num repart_args

	info "Searching for usr + verity partitions"
	wait_partition "usr" "find_usr_partition"
	wait_partition "verity" "find_usr_verity_partition"
	# Calculate A/B usr+verity + root space needed
	disk_mb=$(($(blockdev --getsize64 "$BOOT_DEVICE") / 1024 / 1024))
	usr_mb=$(($(blockdev --getsize64 "$USR_PARTITION") / 1024 / 1024))
	verity_mb=$(($(blockdev --getsize64 "$VERITY_PARTITION") / 1024 / 1024))
	ab_needed_mb=$((usr_mb * 2 + verity_mb * 2))
	min_root_mb=5120  # 5GB
	required_mb=$((ab_needed_mb + min_root_mb))

	info "Disk space analysis:"
	info "  Disk: ${disk_mb}MB"
	info "  USR: ${usr_mb}MB, Verity: ${verity_mb}MB"
	info "  A/B slots need: ${ab_needed_mb}MB"
	info "  Root needs: ${min_root_mb}MB"
	info "  Total required: ${required_mb}MB"

	if [ $disk_mb -lt $required_mb ]; then
		echo "ERROR: Disk too small. Need ${required_mb}MB, have ${disk_mb}MB"
		return 1
	fi

	# Remove any existing root partition, so that it can be recreated with optional encryption
	unset PMOS_ROOT && find_root_partition
	info "Existing root partiton (if found): $PMOS_ROOT"
	root_part_num="$(blkid -p -s PART_ENTRY_NUMBER -o value "$PMOS_ROOT")"
	if [ -n "$root_part_num" ]; then
		info "Removing existing root partition"
		if ! parted -s "$BOOT_DEVICE" rm "$root_part_num"; then
			echo "ERROR: Unable to prepare disk for first boot setup"
			return 1
		fi
	fi

	# Create runtime repart config based on user choices
	mkdir -p /run/repart.d
	local keyfile=""
	if [ -n "$firstboot_fde_password" ]; then
		info "FDE enabled for new root partition"
		# Copy base config and add encryption
		cp /usr/lib/repart.d/30-root.conf /run/repart.d/
		cat >> /run/repart.d/30-root.conf <<- EOF
			Encrypt=key-file
		EOF
		# Create key file for repart
		printf "%s" "$firstboot_fde_password" > /tmp/luks.key
		chmod 0600 /tmp/luks.key
		keyfile="/tmp/luks.key"
	fi

	if ! run_repart "$keyfile"; then
		echo "ERROR: systemd-repart failed"
		return 1
	fi

	# Find the newly created root partition
	unset PMOS_ROOT && find_root_partition
	info "Found new root partition: $PMOS_ROOT"
	if [ -z "$PMOS_ROOT" ]; then
		echo "ERROR: Root partition not found after repart"
		return 1
	fi

	# Unlock automatically if encrypted, since we already have the passphrase
	if [ -n "$firstboot_fde_password" ] && [ -f /tmp/luks.key ]; then
		info "Unlocking new root partition"
		if ! cryptsetup \
				--perf-no_read_workqueue \
				--perf-no_write_workqueue \
				open --key-file=/tmp/luks.key "$PMOS_ROOT" root; then
			echo "ERROR: Failed to unlock encrypted root partition"
			return 1
		fi
		PMOS_ROOT="/dev/mapper/root"
	fi

	# Clean up key file
	rm -f /tmp/luks.key

	return 0
}

# Create user account and run systemd-firstboot
# Uses: firstboot_* variables from get_firstboot_config
# Sets: (none)
# Returns: 1 if user setup fails, 0 on success
setup_first_boot_system() {
	# Manually copy user/group files from factory, we want to append to these
	info "Creating skeleton /etc with user/group databases from factory"
	mkdir -p /sysroot/etc
	for f in passwd group shadow; do
		if ! cp -a /sysroot/usr/share/factory/etc/"$f" /sysroot/etc/; then
			echo "ERROR: Failed to copy factory $f file"
			return 1
		fi
	done

	# useradd later will automatically add the new user to these files if they exist beforehand
	touch /sysroot/etc/subuid
	touch /sysroot/etc/subgid

	# Run systemd-firstboot
	echo "Setting up system configuration..."
	if ! systemd-firstboot --root=/sysroot \
		--keymap=us \
		--locale=en_US.UTF-8 \
		--timezone="UTC" \
		--hostname="$firstboot_hostname"; then
		echo "ERROR: systemd-firstboot failed"
		return 1
	fi

	echo "Creating user account..."
	# Create user account
	if ! useradd --root /sysroot \
		--comment "Default User" \
		--create-home \
		--user-group \
		--shell /bin/ash \
		--groups audio,input,netdev,plugdev,video,wheel,render \
		"$firstboot_username"; then
		echo "ERROR: Failed to create user account"
		return 1
	fi

	# Set password for user account
	info "Configuring user password"
	if ! echo "$firstboot_username:$firstboot_password" | chpasswd -R /sysroot; then
		echo "ERROR: Failed to set user password"
		return 1
	fi

	# Save user's name for future generators
	echo "$firstboot_username" > /sysroot/etc/default_user

	# Lock root account
	info "Locking root account"
	echo "root:!" | chpasswd -e -R /sysroot

	# Create essential symlinks
	info "usr merge \o/"
	ln -s /usr/bin /sysroot/bin
	ln -s /usr/sbin /sysroot/sbin
	ln -s /usr/lib /sysroot/lib

	return 0
}

# Handle first boot scenario
# Uses: BOOT_DEVICE, USR_PARTITION, VERITY_PARTITION
# Sets: PMOS_ROOT (via setup_first_boot_partitions)
# Returns: calls fail_halt_boot on error, 0 on success
handle_first_boot() {
	echo "No root partition found - performing first boot setup"
	show_splash "Preparing for first boot..."

	# Get configuration values from user
	get_firstboot_config

	echo "Creating partitions"
	show_splash "Preparing disk..."

	# Create partitions and unlock if encrypted
	if ! setup_first_boot_partitions; then
		show_splash "ERROR: Failed to partition disk"
		fail_halt_boot
	fi

	# Mount root partition (os-release won't exist yet, that's OK)
	try_mount_root_partition
	case $? in
		0) # Success, continue
			;;
		3) # Missing os-release, expected for first boot
			info "Root partition not populated yet, and that's OK"
			;;
		*)  # Other error
			show_splash "ERROR: Failed to mount root partition"
			echo "ERROR: Failed to mount root partition"
			fail_halt_boot
			;;
	esac

	info "Mounting verified usr partition"
	if ! mount_usr_verified; then
		show_splash "ERROR: Failed to mount usr partition"
		fail_halt_boot
	fi

	# Setup user account and system configuration
	show_splash "Configuring system..."
	echo "Configuring system"
	if ! setup_first_boot_system; then
		show_splash "ERROR: Failed to setup user account"
		fail_halt_boot
	fi

	echo "First boot setup complete"
	show_splash "First boot setup complete"
}

# Change a UUID in the form XXXXXXXXXXXXX... to XXXXXXXX-XXXX-XXXX-...
format_raw_uuid(){
	local raw="$1"
	local ret

	# NOTE: parts are extracted below one at a time to help with code
	# readability
	ret="$(echo "$raw" | cut -c1-8)"
	ret="$ret-$(echo "$raw" | cut -c9-12)"
	ret="$ret-$(echo "$raw" | cut -c13-16)"
	ret="$ret-$(echo "$raw" | cut -c17-20)"
	ret="$ret-$(echo "$raw" | cut -c21-32)"

	echo "$ret"
}

# Search for a /usr partition using usrhash
# Uses: usrhash
# Sets: USR_PARTITION
# $1: variable name to store result
# Returns: 0 always
find_usr_partition() {
	# $1: variable to set result to
	local result="$1"
	local usr_uuid_raw usr_uuid

	if [ -z "$USR_PARTITION" ]; then
		# Extract first 128 bits (32 hex chars) for /usr partition UUID
		# shellcheck disable=SC2154
		usr_uuid_raw="$(echo "$usrhash" | cut -c1-32)"
		usr_uuid="$(format_raw_uuid "$usr_uuid_raw")"

		USR_PARTITION="$(readlink -f "/dev/disk/by-partuuid/$usr_uuid" 2>/dev/null)"
	fi

	# Set the result, since using a subshell prevents us from caching
	if [ -n "$result" ]; then eval "$result=\"$USR_PARTITION\""; fi
}

# Search for a /usr verity partition using usrhash
# Uses: usrhash
# Sets: VERITY_PARTITION
# $1: variable name to store result
# Returns: 0 always
find_usr_verity_partition() {
	# $1: variable to set result to
	local result="$1"
	local verity_uuid_raw verity_uuid

	if [ -z "$VERITY_PARTITION" ]; then
		# Extract last 128 bits (32 hex chars) for verity partition UUID
		verity_uuid_raw="$(echo "$usrhash" | cut -c33-64)"
		verity_uuid="$(format_raw_uuid "$verity_uuid_raw")"

		VERITY_PARTITION="$(readlink -f "/dev/disk/by-partuuid/$verity_uuid" 2>/dev/null)"
	fi

	# Set the result, since using a subshell prevents us from caching
	if [ -n "$result" ]; then eval "$result=\"$VERITY_PARTITION\""; fi
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

# Use GPT type to find the appropriate root partition on the booted block device
find_root_on_boot_device() {
	local root_uuid search_dev
	root_uuid="$(get_root_partition_uuid)"

	[ -z "$root_uuid" ] && return 1

	if [ -n "$SUBPARTITION_LOOP" ]; then
		search_dev="$SUBPARTITION_LOOP"
	else
		search_dev="$BOOT_DEVICE"
	fi

	local partition
	for partition in "${search_dev}"*; do
		if blkid -p -s PART_ENTRY_TYPE "$partition" | grep -qi "$root_uuid"; then
		echo "$partition"
		return
		fi
	done
}

# Limit USB storage transfer size to work around dm-verity corruption issue
# See: https://gitlab.postmarketos.org/postmarketOS/duranium/-/issues/1
# Uses: BOOT_DEVICE
# Sets: (none)
# Returns: 0 always
limit_usb_transfer_size() {
	local device_name sysfs_path device_path
	device_name="$(basename "$BOOT_DEVICE")"
	sysfs_path="/sys/block/$device_name/queue/max_sectors_kb"
	device_path="/sys/block/$device_name/device"

	if [ ! -L "$device_path" ]; then
		info "Not setting max_sectors_kb: device path not found"
		return
	fi

	# Check if device symlink contains /usb, indicating it's a usb device. This
	# seems like a safe assumption to make, and it prevents us from applying this
	# workaround for non-usb devices.
	if ! readlink -f "$device_path" | grep -q "/usb"; then
		info "Not setting max_sectors_kb: not a USB device"
		return
	fi

	if [ ! -f "$sysfs_path" ]; then
		info "Not setting max_sectors_kb: sysfs file not found"
		return
	fi

	echo 32 > "$sysfs_path"
	info "Applied USB workaround: set max_sectors_kb=32 for $device_name"
	return
}

# Handle immutable boot with A/B updates and factory reset
# Uses: usrhash
# Sets: BOOT_DEVICE, USR_PARTITION, VERITY_PARTITION, PMOS_ROOT
# Returns: calls fail_halt_boot on error, 0 on success
handle_immutable_boot() {
	# Check usrhash length, fail fast (should be 64 hex characters = 256 bits)
	if [ ${#usrhash} -ne 64 ]; then
		show_splash "ERROR: Unable to boot immutable image!"
		echo "ERROR: usrhash should be 64 hex characters (256 bits)"
		fail_halt_boot
	fi

	setup_efivarfs

	# Make sure loop is loaded, else repart falls back to using a file and it's
	# buggy
	modprobe loop

	if ! find_boot_device; then
		show_splash "ERROR: Unable to find required EFI variable"
		fail_halt_boot
	fi

	limit_usb_transfer_size

	set -x
	# Factory reset handling
	if factory_reset_requested; then
		show_splash "Factory resetting device..."
		echo "Factory reset requested - deleting partitions"

		if ! run_repart; then
			show_splash "ERROR: Factory reset failed"
			echo "ERROR: systemd-repart failed"
			fail_halt_boot
		fi

		# Treat this as a "first boot" since partitions were cleared
		handle_first_boot
		return
	fi
	set +x

	# Try normal boot
	info "Trying normal bootup"
	find_root_partition
	if [ -z "$PMOS_ROOT" ]; then
		info "No root partition found, proceeding to first boot setup"

		handle_first_boot
		return
	fi

	info "Root partition found: $PMOS_ROOT"
	unlock_root_partition
	if ! try_mount_root_partition; then
		info "Unable to mount root, it was not populated, proceeding to first boot setup"
		# Clean up
		if mountpoint -q /sysroot; then
			umount /sysroot
		fi
		cryptsetup close /dev/mapper/root || true

		handle_first_boot
		return
	fi

	info "Root mounted, proceeding with normal boot"
	if ! mount_usr_verified; then
		show_splash "ERROR: Unable to mount OS data"
		fail_halt_boot
	fi
}
