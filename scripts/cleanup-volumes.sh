#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned volumes and removes them
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup orphaned volumes (DEBUG MODE)"
else
    set -eu -o pipefail
fi

mapfile -t os_volumes < <(openstack --os-cloud "$os_cloud" volume list -f value -c ID --status Available)

if [[ ${#os_volumes[@]} -eq 0 ]]; then
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ No orphaned volumes found"
else
    for volume in "${os_volumes[@]}"; do
        [[ "$DEBUG" == "true" ]] && echo "Deleting volume: $volume"
        openstack --os-cloud "$os_cloud" volume delete "$volume"
    done
    echo "deleted_count=${#os_volumes[@]}" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ Deleted ${#os_volumes[@]} orphaned volume(s)"
fi
