#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Protects OpenStack images that are currently in use
#
# This script marks images prefixed with "ZZCI - " as protected to prevent
# them from being purged by the image cleanup script.
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Protect in-use images (DEBUG MODE)"
else
    set -eu -o pipefail
fi

# Get list of all CI-managed images (prefixed with "ZZCI - ")
mapfile -t images < <(openstack --os-cloud "$os_cloud" image list \
    -f value -c Name | grep "^ZZCI - " | sort -u)

if [[ ${#images[@]} -eq 0 ]]; then
    echo "protected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ No ZZCI images found"
    exit 0
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Found ${#images[@]} ZZCI images to check for protection"

protected_count=0
for image in "${images[@]}"; do
    os_image_protected=$(openstack --os-cloud "$os_cloud" \
        image show "$image" -f value -c protected 2>/dev/null || echo "False")
    
    if [[ "$DEBUG" == "true" ]]; then
        echo "Protected setting for $image: $os_image_protected"
    fi

    if [[ $os_image_protected != "True" ]]; then
        [[ "$DEBUG" == "true" ]] && echo "    Image NOT set as protected, changing the protected value."
        openstack --os-cloud "$os_cloud" image set --protected "$image"
    fi
    ((protected_count++))
done

echo "protected_count=$protected_count" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "✅ Protected $protected_count image(s)"
