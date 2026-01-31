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

# Test OpenStack connectivity before processing
if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Testing OpenStack connectivity..."
fi

set +e  # Temporarily disable exit on error for auth test
openstack --os-cloud "$os_cloud" token issue &>/dev/null
auth_result=$?
set -e  # Re-enable exit on error

if [[ $auth_result -ne 0 ]]; then
    echo "❌ ERROR: OpenStack authentication failed or API unavailable"
    echo "protected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 1
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: OpenStack authentication successful"

# Get list of all CI-managed images (prefixed with "ZZCI - ") with retry logic
for attempt in {1..3}; do
    if mapfile -t images < <(openstack --os-cloud "$os_cloud" image list \
        -f value -c Name 2>&1 | grep "^ZZCI - " | sort -u); then
        break
    else
        if [[ $attempt -lt 3 ]]; then
            echo "⚠️  Warning: Image list attempt $attempt failed, retrying in 5s..."
            sleep 5
        else
            echo "❌ ERROR: Failed to retrieve image list after 3 attempts"
            echo "protected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
            exit 1
        fi
    fi
done

if [[ ${#images[@]} -eq 0 ]]; then
    echo "protected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ No ZZCI images found"
    exit 0
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Found ${#images[@]} ZZCI images to check for protection"

protected_count=0
failed_count=0
for image in "${images[@]}"; do
    os_image_protected=$(openstack --os-cloud "$os_cloud" \
        image show "$image" -f value -c protected 2>/dev/null || echo "False")

    if [[ "$DEBUG" == "true" ]]; then
        echo "Protected setting for $image: $os_image_protected"
    fi

    if [[ $os_image_protected != "True" ]]; then
        [[ "$DEBUG" == "true" ]] && echo "    Image NOT set as protected, changing the protected value."
        if openstack --os-cloud "$os_cloud" image set --protected "$image" 2>&1; then
            ((protected_count++)) || true
        else
            echo "⚠️  Warning: Failed to protect image: $image"
            ((failed_count++)) || true
        fi
    else
        ((protected_count++)) || true
    fi
done

if [[ $failed_count -gt 0 ]]; then
    echo "⚠️  Warning: Failed to protect $failed_count image(s)"
fi

echo "protected_count=$protected_count" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "✅ Protected $protected_count image(s)"
