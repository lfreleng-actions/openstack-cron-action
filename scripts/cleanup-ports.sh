#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned ports and removes them
# Removes ports older than the configured age (default: 30 minutes)
# Based on: global-jjb/shell/openstack-cleanup-orphaned-ports.sh
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
age="${PORT_CLEANUP_AGE:-30 minutes ago}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup orphaned ports (DEBUG MODE)"
else
    set -eu -o pipefail
fi

tmpfile=$(mktemp --suffix=-openstack-ports.txt)
cores=$(nproc --all)
threads=$((3*cores))
regex_created_at='^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})Z$'

# Set cutoff time for deletion
cutoff=$(date -d "$age" +%s)

# Runs once per port under GNU parallel: return 0 for a port that is
# skipped or already gone, and non-zero only for a real client failure
_cleanup()
{
    local uuid=$1
    local created_at created_at_uxts errfile error

    errfile=$(mktemp --suffix=-openstack-port-error.txt)
    if ! created_at=$(openstack --os-cloud "$os_cloud" port show \
            -f value -c created_at "$uuid" 2>"$errfile"); then
        error=$(<"$errfile")
        rm -f "$errfile"
        if [[ "$error" == *"No Port found for"* ]]; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "Port no longer exists; skipping: $uuid"
            fi
            return 0
        fi
        echo "Error: failed to show port $uuid: $error" >&2
        return 1
    fi
    rm -f "$errfile"

    if [ "$created_at" == "None" ]; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "No value for port creation time; skipping: $uuid"
        fi
        return 0
    fi

    if ! echo "$created_at" | grep -qP "$regex_created_at"; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "Unknown/unexpected value for created_at: ${created_at}"
        fi
        return 0
    fi

    created_at_uxts=$(date -d "$created_at" +"%s")

    # Cleanup objects where created_at is older than specified cutoff time
    if [[ "$created_at_uxts" -ge "$cutoff" ]]; then
        return 0
    fi

    if [[ "$DEBUG" == "true" ]]; then
        echo "Removing orphaned port $uuid created $created_at_uxts > $age"
    fi
    if ! error=$(openstack --os-cloud "$os_cloud" port delete "$uuid" 2>&1); then
        if [[ "$error" == *"No Port found for"* ]]; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "Port no longer exists; skipping: $uuid"
            fi
            return 0
        fi
        echo "Error: failed to delete port $uuid: $error" >&2
        return 1
    fi
    return 0
}

_rmtemp()
{
    if [ -f "$tmpfile" ]; then
        rm -f "$tmpfile"
    fi
}

trap _rmtemp EXIT

# Output the initial list of port UUIDs to a temporary file
openstack --os-cloud "$os_cloud" port list -f value -c ID -c status \
    | { grep -e DOWN || true; } | { awk '{print $1}' || true; } > "$tmpfile"

# Count the number to process
total=$(wc -l "$tmpfile" | awk '{print $1}')

if [ "$total" -eq 0 ]; then
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ No orphaned ports found"
    exit 0
fi

[[ "$DEBUG" == "true" ]] && echo "Ports to process: $total; age limit: $cutoff"
[[ "$DEBUG" == "true" ]] && echo "Using $threads parallel processes..."

# Export variables and send to parallel for processing
export -f _cleanup
export os_cloud cutoff age regex_created_at DEBUG
if [[ "$DEBUG" == "true" ]]; then
    parallel --progress --retries 3 -j "$threads" _cleanup < "$tmpfile"
else
    parallel --retries 3 -j "$threads" _cleanup < "$tmpfile"
fi

echo "deleted_count=$total" >> "${GITHUB_OUTPUT:-/dev/null}"
echo "✅ Deleted $total orphaned port(s)"
