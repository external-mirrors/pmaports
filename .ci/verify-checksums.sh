#!/bin/sh -e
# Description: verify checksums of modified packages
# Options: native
# Use 'native' because it requires running pmbootstrap.
# https://nura.eco/pmb-ci

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.nura.eco/nura/ci-common/-/raw/main/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

export PYTHONUNBUFFERED=1

.ci/lib/verify_checksums.py
