#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned stacks
# Checks Jenkins URLs to avoid deleting stacks in active use
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
jenkins_urls="${JENKINS_URLS:-}"
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

# Use lftools to cleanup orphaned stacks
if [[ -n "$jenkins_urls" ]]; then
    if [[ "$DEBUG" == "true" ]]; then
        echo "INFO: Will check Jenkins URLs for active builds: $jenkins_urls"
    fi
    # lftools stack delete-stale takes jenkins URLs as positional arguments
    # shellcheck disable=SC2086
    if lftools openstack --os-cloud "$os_cloud" stack delete-stale $jenkins_urls; then
        # Note: lftools doesn't return count, so we set a placeholder
        echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
        echo "✅ Stack cleanup complete"
    else
        exit_code=$?
        echo "⚠️  Stack cleanup failed with exit code $exit_code"
        echo "⚠️  Known issue: lftools delete() method signature mismatch"
        echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
        # Don't fail the entire workflow for this known issue
        exit 0
    fi
else
    echo "⚠️  No Jenkins URLs provided, skipping stack cleanup"
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
