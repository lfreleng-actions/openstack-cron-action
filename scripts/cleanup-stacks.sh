#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned stacks
# Checks Jenkins URLs to avoid deleting stacks in active use
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
jenkins_urls="${JENKINS_URLS:-}"
# Path the action installed lftools-uv to; otherwise found on PATH
lftools_uv="${LFTOOLS_UV:-lftools-uv}"
DEBUG="${DEBUG:-false}"

# Set verbose mode only if debug enabled
if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup orphaned stacks (DEBUG MODE)"
else
    set -eu -o pipefail
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Checking for orphaned stacks on cloud: $os_cloud"
fi

# Use lftools-uv to cleanup orphaned stacks
if [[ -n "$jenkins_urls" ]]; then
    if [[ "$DEBUG" == "true" ]]; then
        echo "INFO: Will check Jenkins URLs for active builds: $jenkins_urls"
    fi
    # lftools-uv stack delete-stale takes jenkins URLs as positional arguments
    # shellcheck disable=SC2086
    if "$lftools_uv" openstack --os-cloud "$os_cloud" stack delete-stale $jenkins_urls; then
        # Note: lftools-uv doesn't return count, so we set a placeholder
        echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
        echo "✅ Stack cleanup complete"
    else
        exit_code=$?
        echo "::error::Stack cleanup failed with exit code $exit_code"
        echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
        # Let the remaining cleanup steps run; the action fails at the end
        echo "failed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
    fi
else
    echo "⚠️  No Jenkins URLs provided, skipping stack cleanup"
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
