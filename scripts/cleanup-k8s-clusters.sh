#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Scans OpenStack for orphaned Kubernetes clusters
# Checks Jenkins URLs to avoid deleting clusters in active use
# Based on: global-jjb/shell/openstack-cleanup-orphaned-k8s-clusters.sh
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
jenkins_urls="${JENKINS_URLS:-}"
DEBUG="${DEBUG:-false}"

# Set verbose mode only if debug enabled
if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Cleanup orphaned K8s clusters (DEBUG MODE)"
else
    set -eu -o pipefail
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Checking for orphaned K8s clusters on cloud: $os_cloud"

if [[ -z "$jenkins_urls" ]]; then
    echo "⚠️  No Jenkins URLs provided, skipping cluster cleanup"
    echo "deleted_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Will check Jenkins URLs for active builds: $jenkins_urls"

cluster_in_jenkins() {
    # Usage: cluster_in_jenkins CLUSTER_NAME JENKINS_URL [JENKINS_URL...]
    # Returns: 0 If CLUSTER_NAME is in Jenkins and 1 if CLUSTER_NAME is not in Jenkins.

    CLUSTER_NAME="${1}"

    builds=()
    for jenkins in "${@:2}"; do
        PARAMS="tree=computer[executors[currentExecutable[url]],"
        PARAMS=$PARAMS"oneOffExecutors[currentExecutable[url]]]"
        PARAMS=$PARAMS"&xpath=//url&wrapper=builds"
        JENKINS_URL="$jenkins/computer/api/json?$PARAMS"
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
        builds=(${builds[@]} $(echo "$json_data" | jq -r '.computer[].executors[].currentExecutable.url' | grep -v null | sed -e 's#/$##' -e 's#.*/##'))
        # shellcheck disable=SC2206,SC2207
        builds=(${builds[@]} $(echo "$json_data" | jq -r '.computer[].oneOffExecutors[].currentExecutable.url' | grep -v null | sed -e 's#/$##' -e 's#.*/##'))
    done

    if [[ "${builds[*]}" =~ $CLUSTER_NAME ]]; then
        return 0
    fi

    return 1
}

# Fetch cluster list
mapfile -t OS_COE_CLUSTERS < <(openstack --os-cloud "$os_cloud" coe cluster list -f value -c "name")

[[ "$DEBUG" == "true" ]] && echo "INFO: Found ${#OS_COE_CLUSTERS[@]} clusters to check"

# Search for clusters not in use by any active Jenkins systems and remove them.
deleted_count=0
deleted_clusters=()
for cluster in "${OS_COE_CLUSTERS[@]}"; do
    # jenkins_urls intentionally needs globbing to be passed as separate params.
    # shellcheck disable=SC2153,SC2086
    if cluster_in_jenkins "$cluster" $jenkins_urls; then
        [[ "$DEBUG" == "true" ]] && echo "INFO: Cluster $cluster is in use, skipping"
        continue
    else
        [[ "$DEBUG" == "true" ]] && echo "INFO: Deleting orphaned cluster: $cluster"
        lftools openstack --os-cloud "$os_cloud" cluster delete --minutes 15 "$cluster"
        deleted_clusters+=("$cluster")
        ((deleted_count++)) || true
    fi
done

# Output for GitHub Actions
echo "deleted_count=$deleted_count" >> "${GITHUB_OUTPUT:-/dev/null}"

# Summary output (always shown)
if [[ $deleted_count -gt 0 ]]; then
    if [[ "$DEBUG" == "false" ]]; then
        echo "✅ Deleted $deleted_count cluster(s): ${deleted_clusters[*]}"
    else
        echo "✅ K8s cluster cleanup complete - deleted $deleted_count cluster(s)"
    fi
else
    echo "✅ No orphaned K8s clusters found"
fi
