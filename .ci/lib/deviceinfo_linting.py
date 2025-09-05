#!/usr/bin/env python3
# Copyright 2025 Stefan Hansson
# SPDX-License-Identifier: GPL-3.0-or-later

import common
import os.path
import subprocess
import sys

if __name__ == "__main__":
    common.add_upstream_git_remote()
    deviceinfo_files = {file for file in common.get_changed_files(removed=False)
                        if os.path.basename(file) == "deviceinfo"}

    try:
        subprocess.run(["dint", "check", *deviceinfo_files], text=True, check=True)
    except subprocess.CalledProcessError as exception:
        sys.exit(exception.returncode)
