#!/bin/sh
# shellcheck disable=SC3043

set -eu

# Create test environment
TEST_ROOT=$(mktemp -d)
export SYSTEMD_APK_ROOT="$TEST_ROOT"

# This is used to try and check that tests are running from TEST_ROOT, instead
# of real root (/)
check_safe_path() {
	case "$1" in
		"$TEST_ROOT"/*) ;;
		*) echo "UNSAFE: $1 not in test root" >&2; exit 1 ;;
	esac
}

# shellcheck disable=SC1091
. ./rootfs-usr-libexec-systemd-apk-trigger

TEST_COUNT=0
PASS_COUNT=0

assert_exists() {
	TEST_COUNT=$((TEST_COUNT + 1))
	check_safe_path "$1"
	if [ -e "$1" ]; then
		echo "PASS: $1 exists"
		PASS_COUNT=$((PASS_COUNT + 1))
	else
		echo "FAIL: $1 should exist but doesn't"
	fi
}

assert_not_exists() {
	TEST_COUNT=$((TEST_COUNT + 1))
	# Don't check_safe_path here since file might not exist
	if [ ! -e "$1" ]; then
		echo "PASS: $1 correctly removed"
		PASS_COUNT=$((PASS_COUNT + 1))
	else
		echo "FAIL: $1 should be removed but still exists"
		check_safe_path "$1"
	fi
}

# shellcheck disable=SC2329
cleanup() {
	[ -n "$TEST_ROOT" ] && rm -rf "$TEST_ROOT"
}

trap cleanup EXIT

test_remove_unit_symlinks() {
	echo "Testing unit symlink removal..."

	# Create existing units (controls)
	touch "usr/lib/systemd/system/kept.service"
	touch "usr/lib/systemd/user/kept-user.service"

	# Test case 1: Direct absolute symlinks
	ln -s "$TEST_ROOT/usr/lib/systemd/system/removed.service" "etc/systemd/system/direct-system.service"
	ln -s "$TEST_ROOT/usr/lib/systemd/user/removed-user.service" "etc/systemd/user/direct-user.service"

	# Test case 2: Relative symlinks
	ln -s "../../../usr/lib/systemd/system/removed.service" "etc/systemd/system/relative-system.service"
	ln -s "../../../usr/lib/systemd/user/removed-user.service" "etc/systemd/user/relative-user.service"

	# Test case 3: Chain symlinks (intermediate -> removed unit, final -> intermediate)
	ln -s "$TEST_ROOT/usr/lib/systemd/system/removed.service" "etc/systemd/system/intermediate-system.service"
	ln -s "intermediate-system.service" "etc/systemd/system/chain-system.service"

	# Test case 4: Control symlinks (should remain)
	ln -s "$TEST_ROOT/usr/lib/systemd/system/kept.service" "etc/systemd/system/control-system.service"
	ln -s "$TEST_ROOT/usr/lib/systemd/user/kept-user.service" "etc/systemd/user/control-user.service"

	echo "Running remove_unit_symlinks for system units..."
	remove_unit_symlinks "/usr/lib/systemd/system/removed.service"

	echo "Running remove_unit_symlinks for user units..."
	remove_unit_symlinks "/usr/lib/systemd/user/removed-user.service"

	echo "Verifying results..."

	# Should be removed
	assert_not_exists "$TEST_ROOT/etc/systemd/system/direct-system.service"
	assert_not_exists "$TEST_ROOT/etc/systemd/system/relative-system.service"
	assert_not_exists "$TEST_ROOT/etc/systemd/system/intermediate-system.service"
	assert_not_exists "$TEST_ROOT/etc/systemd/system/chain-system.service"
	assert_not_exists "$TEST_ROOT/etc/systemd/user/direct-user.service"
	assert_not_exists "$TEST_ROOT/etc/systemd/user/relative-user.service"

	# Should remain
	assert_exists "$TEST_ROOT/etc/systemd/system/control-system.service"
	assert_exists "$TEST_ROOT/etc/systemd/user/control-user.service"
	assert_exists "$TEST_ROOT/usr/lib/systemd/system/kept.service"
	assert_exists "$TEST_ROOT/usr/lib/systemd/user/kept-user.service"
}

test_parse_diff_output() {
	echo "Testing diff parsing..."

	local diff_output="--- old
+++ new
@@ -1,3 +1,4 @@
-/usr/lib/systemd/system/removed.service type=file mtime=123
+/usr/lib/systemd/system/added.service type=file mtime=456
+/usr/lib/systemd/system/another-added.service type=file mtime=789
 /usr/lib/systemd/system/unchanged.service type=file mtime=999"

	local added_result removed_result
	parse_diff_output "$diff_output" "added_result" "removed_result"

	# Check results
	case " $added_result " in
		*" /usr/lib/systemd/system/added.service "*)
			echo "PASS: added.service found in added paths"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: added.service not found in added paths" ;;
	esac
	TEST_COUNT=$((TEST_COUNT + 1))

	case " $added_result " in
		*" /usr/lib/systemd/system/another-added.service "*)
			echo "PASS: another-added.service found in added paths"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: another-added.service not found in added paths" ;;
	esac
	TEST_COUNT=$((TEST_COUNT + 1))

	case " $removed_result " in
		*" /usr/lib/systemd/system/removed.service "*)
			echo "PASS: removed.service found in removed paths"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: removed.service not found in removed paths" ;;
	esac
	TEST_COUNT=$((TEST_COUNT + 1))

	# Test directory filtering
	local dir_diff="--- old
+++ new
@@ -1,2 +1,3 @@
-/usr/lib/systemd/system/some.service type=file mtime=123
+/usr/lib/systemd/system/target.wants type=dir mtime=456
+/usr/lib/systemd/system/new.service type=file mtime=789"

	# shellcheck disable=SC2034
	local dir_added dir_removed
	parse_diff_output "$dir_diff" "dir_added" "dir_removed"

	case " $dir_added " in
		*" /usr/lib/systemd/system/target.wants "*)
			echo "FAIL: directory incorrectly included in added paths" ;;
		*" /usr/lib/systemd/system/new.service "*)
			echo "PASS: directory filtered out, file included"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: new.service not found in added paths" ;;
	esac
	TEST_COUNT=$((TEST_COUNT + 1))
}

test_trigger_systemd_presets() {
	echo "Testing systemd presets..."

	# Create unit with [Install] section
	cat > "$TEST_ROOT/usr/lib/systemd/system/installable.service" <<-EOF
		[Unit]
		Description=Test service

		[Service]
		Type=simple

		[Install]
		WantedBy=multi-user.target
	EOF

	# Create unit without [Install] section
	cat > "$TEST_ROOT/usr/lib/systemd/system/not-installable.service" <<-EOF
		[Unit]
		Description=Test service

		[Service]
		Type=simple
	EOF

	# Create user unit with [Install]
	cat > "$TEST_ROOT/usr/lib/systemd/user/user-installable.service" <<-EOF
		[Unit]
		Description=User test service

		[Service]
		Type=simple

		[Install]
		WantedBy=default.target
	EOF

	# Test: new installable units should be preset
	local test_output
	test_output=$(trigger_systemd_presets "$TEST_ROOT/usr/lib/systemd/system/installable.service $TEST_ROOT/usr/lib/systemd/user/user-installable.service $TEST_ROOT/usr/lib/systemd/system/not-installable.service" "" 2>&1)

	TEST_COUNT=$((TEST_COUNT + 1))
	case "$test_output" in
		*"systemctl --no-reload preset installable.service"*)
			echo "PASS: system unit preset called"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: system unit preset not called" ;;
	esac

	TEST_COUNT=$((TEST_COUNT + 1))
	case "$test_output" in
		*"systemctl --no-reload preset --global user-installable.service"*)
			echo "PASS: user unit preset called"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
		*) echo "FAIL: user unit preset not called" ;;
	esac

	TEST_COUNT=$((TEST_COUNT + 1))
	case "$test_output" in
		*"not-installable.service"*)
			echo "FAIL: non-installable unit incorrectly preset" ;;
		*) echo "PASS: non-installable unit skipped"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
	esac

	# Test: modified files (added and removed) should be skipped
	local modified_output
	modified_output=$(trigger_systemd_presets "$TEST_ROOT/usr/lib/systemd/system/installable.service" "$TEST_ROOT/usr/lib/systemd/system/installable.service" 2>&1)

	TEST_COUNT=$((TEST_COUNT + 1))
	case "$modified_output" in
		*"installable.service"*)
			echo "FAIL: modified unit incorrectly preset" ;;
		*) echo "PASS: modified unit skipped"
			PASS_COUNT=$((PASS_COUNT + 1)) ;;
	esac
}

# Set up test directory structure
mkdir -p "$TEST_ROOT/etc/systemd/system"
mkdir -p "$TEST_ROOT/etc/systemd/user"
mkdir -p "$TEST_ROOT/usr/lib/systemd/system"
mkdir -p "$TEST_ROOT/usr/lib/systemd/user"

# Change to test directory for relative path resolution
cd "$TEST_ROOT"

test_remove_unit_symlinks
test_parse_diff_output
test_trigger_systemd_presets

echo
echo "Test results: $PASS_COUNT/$TEST_COUNT tests passed"

if [ "$PASS_COUNT" -eq "$TEST_COUNT" ]; then
	echo "ALL TESTS PASSED"
	exit 0
else
	echo "SOME TESTS FAILED"
	exit 1
fi
