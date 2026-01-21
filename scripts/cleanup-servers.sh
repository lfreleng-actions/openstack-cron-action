#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned servers/instances
# Checks Jenkins URLs to avoid deleting servers in active use
# Based on: global-jjb/shell/openstack-cleanup-orphaned-servers.sh
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
jenkins_urls="${JENKINS_URLS:-}"
DEBUG="${DEBUG:-false}"

# Set verbose mode only if debug enabled
if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup orphaned servers (DEBUG MODE)"
else
    set -eu -o pipefail
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Checking for orphaned servers on cloud: $os_cloud"
fi

if [[ -z "$jenkins_urls" ]]; then
    echo "⚠️  No Jenkins URLs provided, skipping server cleanup"
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Will check Jenkins URLs for active builds: $jenkins_urls"
fi

minion_in_jenkins() {
    # Usage: minion_in_jenkins MINION JENKINS_URL [JENKINS_URL...]
    # Returns: 0 If minion is in Jenkins and 1 if minion is not in Jenkins.

    MINION="${1}"

    minions=()
    for jenkins in "${@:2}"; do
        JENKINS_URL="$jenkins/computer/api/json?tree=computer[displayName]"
        resp=$(curl -s -w "\\n\\n%{http_code}" --globoff -H "Content-Type:application/json" "$JENKINS_URL")
        json_data=$(echo "$resp" | head -n1)
        status=$(echo "$resp" | awk 'END {print $NF}')

        if [ "$status" != 200 ]; then
            >&2 echo "ERROR: Failed to fetch data from $JENKINS_URL with status code $status"
            >&2 echo "$resp"
            exit 1
        fi

        # We purposely want to wordsplit here to combine the arrays
        # shellcheck disable=SC2206,SC2207
        minions=(${minions[@]} $(echo "$json_data" | \
            jq -r '.computer[].displayName' | grep -v master)
        )
    done

    if [[ "${minions[*]}" =~ $MINION ]]; then
        return 0
    fi

    return 1
}

# Fetch server list before checking active minions to minimize race condition
mapfile -t OS_SERVERS < <(openstack --os-cloud "$os_cloud" server list -f value -c "Name" | grep -E 'prd|snd|bastion-gh')

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Found ${#OS_SERVERS[@]} servers to check"
fi

# Search for servers not in use by any active Jenkins systems and remove them.
deleted_count=0
deleted_servers=()
for server in "${OS_SERVERS[@]}"; do
    # jenkins_urls intentionally needs globbing to be passed as separate params.
    # shellcheck disable=SC2153,SC2086
    if minion_in_jenkins "$server" $jenkins_urls; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "INFO: Server $server is in use, skipping"
        fi
        continue
    else
        if [[ "$DEBUG" == "true" ]]; then
            echo "INFO: Deleting orphaned server: $server"
        fi
        lftools openstack --os-cloud "$os_cloud" \
            server remove --minutes 15 "$server"
        deleted_servers+=("$server")
        ((deleted_count++))
    fi
done

# Output for GitHub Actions
echo "deleted_count=$deleted_count" >> "${GITHUB_OUTPUT:-/dev/null}"

# Summary output (always shown)
if [[ $deleted_count -gt 0 ]]; then
    if [[ "$DEBUG" == "false" ]]; then
        echo "✅ Deleted $deleted_count server(s): ${deleted_servers[*]}"
    else
        echo "✅ Server cleanup complete - deleted $deleted_count server(s)"
    fi
else
    echo "✅ No orphaned servers found"
fi
