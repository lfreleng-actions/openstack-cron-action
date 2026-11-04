#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Removes OpenStack images older than X days in the cloud
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
os_image_cleanup_age="${OS_IMAGE_CLEANUP_AGE:-30}"
# Path the action installed lftools-uv to; otherwise found on PATH
lftools_uv="${LFTOOLS_UV:-lftools-uv}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup old images (DEBUG MODE)"
else
    set -eu -o pipefail
fi

# Capture lftools-uv output to count deleted images. It exits 1 when any
# image fails to delete; report that, but carry on (see the guard below).
status=0
output=$("$lftools_uv" openstack --os-cloud "${os_cloud}" image cleanup \
    --days="${os_image_cleanup_age}" 2>&1) || status=$?
printf '%s\n' "$output"
if [[ "${status}" -ne 0 ]]; then
    echo "::warning title=Image cleanup reported errors::lftools-uv exited ${status}; see the log above"
fi

# Count lines matching 'Removed "..." from <cloud>.'
deleted_count=$(printf '%s\n' "$output" | grep -c '^Removed "' || true)
# Count images lftools-uv selected, summed over clouds: 'Removing N images from <cloud>.'
targeted_count=$(printf '%s\n' "$output" | awk '/^Removing [0-9]+ images from /{sum+=$2} END{print sum+0}')
echo "deleted_count=${deleted_count}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "targeted_count=${targeted_count}" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "✅ Old image cleanup complete (${deleted_count} of ${targeted_count} images removed)"

# A run that selects images and deletes none is a silent no-op: lftools-uv skips
# and keeps skipping, so the same images are retried every run forever. Warn
# only. This must not fail the step or the cleanup stages after it.
if [[ "${targeted_count}" -gt 0 && "${deleted_count}" -eq 0 ]]; then
    echo "::warning title=Image cleanup removed nothing::Selected ${targeted_count} image(s) for removal but removed 0. Check the log for skip reasons (duplicate image names, protected, shared, or owned by another project)."
fi
