#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Removes OpenStack images older than X days in the cloud
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
os_image_cleanup_age="${OS_IMAGE_CLEANUP_AGE:-30}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup old images (DEBUG MODE)"
else
    set -eu -o pipefail
fi

# Capture lftools output to count deleted images
output=$(lftools openstack --os-cloud "${os_cloud}" image cleanup \
    --days="${os_image_cleanup_age}" 2>&1) || true
echo "$output"

# Count lines matching 'Removed "..." from <cloud>.'
deleted_count=$(echo "$output" | grep -c '^Removed "' || true)
echo "deleted_count=${deleted_count}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "✅ Old image cleanup complete (${deleted_count} images removed)"
