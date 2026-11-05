#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Removes orphaned Kubernetes (COE) clusters with lftools-uv, which:
#  - reads the running builds from every Jenkins first, and deletes nothing
#    when any Jenkins cannot be read;
#  - keeps clusters whose name a running build's silo-job-build name holds;
#  - keeps long-lived '-managed-prod-k8s-' and '-managed-test-k8s-' clusters.
# Based on: global-jjb/shell/openstack-cleanup-orphaned-k8s-clusters.sh
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
jenkins_urls="${JENKINS_URLS:-}"
# Path the action installed lftools-uv to; otherwise found on PATH
lftools_uv="${LFTOOLS_UV:-lftools-uv}"
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

# Capture lftools-uv output to count deleted clusters
status=0
output=$("$lftools_uv" openstack --os-cloud "$os_cloud" cluster cleanup \
    --jenkins "$jenkins_urls" 2>&1) || status=$?
printf '%s\n' "$output"

deleted_count=$(printf '%s\n' "$output" | grep -c '^Successfully deleted cluster: ' || true)
echo "deleted_count=$deleted_count" >> "${GITHUB_OUTPUT:-/dev/null}"

if [[ "$status" -ne 0 ]]; then
    # lftools-uv exits 1 when it cannot read a Jenkins or list the clusters,
    # having deleted nothing, or when a cluster fails to delete. Let the
    # remaining cleanup steps run; the action fails at the end.
    echo "::error::K8s cluster cleanup failed with exit code $status"
    echo "failed=true" >> "${GITHUB_OUTPUT:-/dev/null}"
elif [[ "$deleted_count" -gt 0 ]]; then
    echo "✅ Deleted $deleted_count orphaned K8s cluster(s)"
else
    echo "✅ No orphaned K8s clusters found"
fi
