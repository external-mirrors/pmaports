#!/bin/bash

kernel_configs=""

# $1: file path
apply_jinja_template() {
	filepath="$1"
	filename="$(basename "$filepath")"
	# builddir is defined in APKBUILD
	# shellcheck disable=SC2154
	makefile="$builddir"/Makefile
	kernel_version="$(grep "^VERSION" "$makefile" | sed -e "s/VERSION = //")"
	kernel_patchlevel="$(grep "^PATCHLEVEL" "$makefile" | sed -e "s/PATCHLEVEL = //")"
	# shellcheck disable=SC2154
	jinja2 --strict \
		-D kernel_version="$kernel_version" \
		-D kernel_patchlevel="$kernel_patchlevel" \
		-D arch="$_carch" \
		"$filepath" > "$builddir"/kernel/configs/"${filename%.j2}"
}

validate_all_configs() {
    local _config_file="$builddir"/.config

    set -x
    # Collect all requirements from all fragments
    local all_requirements=""
    for fragment in ${kernel_configs//.j2/}; do
        fragment_file="$builddir/kernel/configs/$fragment"
        if [ -f "$fragment_file" ]; then
            all_requirements="$all_requirements $(cat "$fragment_file")"
        fi
    done

    # Process =y and =m requirements with dependency analysis
    while IFS= read -r line; do
        option="${line%=*}"
        value="${line#*=}"

        if ! grep -q "^$line$" "$_config_file"; then
            echo "ERROR: $line not set in final config!"
            EXIT_CODE=1

            # Do dependency analysis for missing options
            if [ "$value" = "y" ] || [ "$value" = "m" ]; then
                # Check if this option exists but with different value
                actual_value=$(grep "^${option}=" "$_config_file" | cut -d= -f2)
                if [ -n "$actual_value" ]; then
                    echo "  Note: $option is =$actual_value instead of =$value"

                    # Check for =y depending on =m issue
                    if [ "$value" = "y" ] && [ "$actual_value" = "m" ]; then
                        echo "  Hint: Built-in options can't depend on modules"
                    fi
                else
                    # Option is completely missing - check dependencies
                    analyze_missing_option "$option" "$value" "$all_requirements"
                fi
            fi
        fi
    done < <(echo "$all_requirements" | grep -E "^CONFIG_[A-Z0-9_]+=[ym]" | cut -d'#' -f1 | tr -d ' ' | sort -u)

    # Process =n requirements
    while IFS= read -r line; do
        option="${line%=n}"
        if ! grep -q "# $option is not set" "$_config_file"; then
            echo "ERROR: $option must NOT be set!"
            EXIT_CODE=1
        fi
    done < <(echo "$all_requirements" | grep -E "^CONFIG_[A-Z0-9_]+=n" | cut -d'#' -f1 | tr -d ' ')

    # Process string requirements
    while IFS= read -r line; do
        if ! grep -q "^$line$" "$_config_file"; then
            echo "ERROR: $line not found in final config!"
            EXIT_CODE=1
        fi
    done < <(echo "$all_requirements" | grep -E "^CONFIG_[A-Z0-9_]+=\".*\"" | cut -d'#' -f1 | tr -d ' ')

    return $EXIT_CODE
}

# Helper function to analyze why an option is missing
analyze_missing_option() {
    local option="$1"
    local wanted_value="$2"
    local all_requirements="$3"
    local config_name="${option#CONFIG_}"

    # Find Kconfig file for this option
    local kconfig
    kconfig=$(find . -name 'Kconfig*' -type f -exec grep -l "^config $config_name$" {} \; 2>/dev/null | head -n1)

    if [ -z "$kconfig" ]; then
        echo "  WARNING: Could not find Kconfig definition for $option"
        return
    fi

    # Extract dependencies from Kconfig
    local deps
    deps=$(awk -v opt="$config_name" '
    /^config / { 
        if (in_block) exit
        in_block = ($2 == opt)
    }
    in_block && /depends on/ {
        sub(/.*depends on[[:space:]]+/, "")
        print
    }
    ' "$kconfig" | grep -oE '[A-Z][A-Z0-9_]+' | sed 's/^/CONFIG_/' | sort -u)

    if [ -n "$deps" ]; then
        echo "  Missing dependencies:"
        for dep in $deps; do
            if ! echo "$all_requirements" | grep -q "^$dep="; then
                echo "    - $dep (not in any fragment)"
            elif [ "$wanted_value" = "y" ]; then
                dep_value=$(echo "$all_requirements" | grep "^$dep=" | cut -d= -f2 | head -n1)
                if [ "$dep_value" = "m" ]; then
                    echo "    - $dep is =m but needs to be =y (for built-in $option)"
                fi
            fi
        done
    fi
}

# if full config is supplied instead of defconfig, copy it.
copy_full_config() {
	# shellcheck disable=SC2154
	# _config and srcdir are defined in APKBUILD
	if [ -n "$_config" ]; then
		cp "$srcdir/$_config" .config
	fi
}

# if we need only to copy a full config (.e.g. if we want to edit
# it), then we can pass ONLY_COPY=1 to env and the code will end up
# here. This is needed for "pmbootstrap kconfig edit" command when
# using full configs
if [ "$ONLY_COPY" = "1" ]; then
	copy_full_config
	return
fi

# srcdir is defined in APKBUILD
# shellcheck disable=SC2154
fragments_from_package="$(find "$srcdir" -maxdepth 1 -name "*.config" -o -name "*.config.j2")"

if [ -n "$fragments_from_package" ]; then
	for config in $fragments_from_package;
	do
		kernel_configs="$kernel_configs $(basename "$config")"
	done
fi

# mainline is default config fragment
kernel_configs="$kernel_configs mainline.config.j2"

# shellcheck disable=SC2154
# _pmos_uefi is defined in APKBUILD
if [ "$_pmos_uefi" = "true" ]; then
	kernel_configs="$kernel_configs uefi.config.j2"
fi

# copy fragments
# shellcheck disable=SC2154
# builddir is defined in APKBUILD
for config in $kernel_configs; do
	_paths="/usr/share/devicepkg-dev/config-fragments/$config $srcdir/$config"
	for file in $_paths; do
		if [ -f "$file" ]; then
			if [[ "$file" == *.config ]]; then
				cp "$file" "$builddir"/kernel/configs
			elif [[ "$file" == *.config.j2 ]]; then
				apply_jinja_template "$file"
			fi
		fi
	done
done

# copy full config when using it instead of defconfig
# empty _pmos_defconfig won't be a problem
copy_full_config

# apply all the configs, _pmos_defconfig is defined in device package
# shellcheck disable=SC2086,SC2154
# _carch and _pmos_defconfig are defined in APKBUILD
make ARCH="$_carch" $_pmos_defconfig ${kernel_configs//.j2/}

# validate all configs. this will go through all of them, and will
# print all errors. However, it will end the script only after going
# through all configs, because we want to see all problems that
# happen during applying the configs
#
# EXIT_CODE will be set to 1 in validate_config function if there is
# at least one misconfiguration, so we will be able to end up with an
# error on condition of this variable.
EXIT_CODE=0
for config in ${kernel_configs//.j2/};
do
	validate_all_configs
done

if [ "$EXIT_CODE" -ne 0 ]; then
	exit "$EXIT_CODE"
fi
