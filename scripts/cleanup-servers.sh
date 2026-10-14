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
orphan_age_hours="${ORPHAN_SERVER_AGE_HOURS:-24}"

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

# Capped at one year so the minutes conversion cannot overflow
if ! [[ "$orphan_age_hours" =~ ^[1-9][0-9]{0,3}$ ]] || (( orphan_age_hours > 8760 )); then
    echo "::error::orphan_server_age must be an integer from 1 to 8760 (hours), got '$orphan_age_hours'"
    exit 1
fi

# Without Jenkins URLs only the Packer cleanup can run safely
if [[ -z "$jenkins_urls" ]]; then
    echo "⚠️  No Jenkins URLs provided, skipping Jenkins minion and stack server cleanup"
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Will check Jenkins URLs for active builds: $jenkins_urls"
fi

# Helper function to check server age. Returns 0 when old enough, 1 when
# too new and 2 when the age cannot be determined; callers skip on any
# non-zero result. Failures are checked explicitly because errexit does
# not apply inside a function called from a conditional.
is_server_old_enough() {
    local server_id=$1
    local minutes=$2
    local created_at created_epoch now_epoch age_minutes

    if ! created_at=$(openstack --os-cloud "$os_cloud" server show "$server_id" -f value -c created) \
            || [[ -z "$created_at" ]]; then
        echo "⚠️  Warning: Could not read creation time of server $server_id, skipping" >&2
        return 2
    fi
    if ! created_epoch=$(date -d "$created_at" +%s); then
        echo "⚠️  Warning: Could not parse creation time '$created_at' of server $server_id, skipping" >&2
        return 2
    fi
    now_epoch=$(date +%s)
    age_minutes=$(( (now_epoch - created_epoch) / 60 ))

    if [[ $age_minutes -ge $minutes ]]; then
        return 0  # Old enough
    else
        return 1  # Too new
    fi
}

# Packer templates set server metadata ci_managed=yes. Returns non-zero
# when the marker is missing or the lookup fails.
is_ci_managed() {
    local server_id=$1
    local props

    props=$(openstack --os-cloud "$os_cloud" server show "$server_id" -f json -c properties) || return 1
    jq -e '.properties
        | if type == "object" then .ci_managed == "yes"
          else tostring | test("(^|, )ci_managed=\u0027yes\u0027(,|$)") end' \
        <<< "$props" > /dev/null
}

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

# Derive Jenkins silo names the same way lftools does for stack names
silos=()
for jenkins in $jenkins_urls; do
    IFS='/' read -r -a url_parts <<< "${jenkins%/}"
    if [[ ${#url_parts[@]} -eq 4 ]]; then
        silos+=("${url_parts[3]}")
    elif [[ ${#url_parts[@]} -eq 3 ]]; then
        silos+=("production")
    fi
done

# Server names are <silo>-<n>-<n>-...; silos are compared as literal
# prefixes so characters such as "." in a silo are not regex wildcards.
is_stack_server_name() {
    local name=$1 silo
    for silo in "${silos[@]}"; do
        if [[ "$name" == "$silo-"* && "${name#"$silo-"}" =~ ^[0-9]+-[0-9]+- ]]; then
            return 0
        fi
    done
    return 1
}

# Packer build instances are named <distro>-<template>-<uuid>
packer_server_regex='-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Fetch server list with both ID and Name to handle duplicates
# Format: "server-id server-name"
OS_SERVERS=()
if [[ -n "$jenkins_urls" ]]; then
    if ! minion_servers_out=$(openstack --os-cloud "$os_cloud" server list -f value -c "ID" -c "Name"); then
        echo "::error::Could not list servers for Jenkins minion cleanup"
        exit 1
    fi
    mapfile -t OS_SERVERS < <(grep -E 'prd|snd|bastion-gh' <<< "$minion_servers_out" || true)
fi

if [[ "$DEBUG" == "true" ]]; then
    echo "INFO: Found ${#OS_SERVERS[@]} servers to check"
fi

# Search for servers not in use by any active Jenkins systems and remove them.
deleted_count=0
deleted_servers=()
for server_line in "${OS_SERVERS[@]}"; do
    # Parse ID and Name from line
    server_id=$(echo "$server_line" | awk '{print $1}')
    server_name=$(echo "$server_line" | awk '{$1=""; print $0}' | sed 's/^ //')

    # Stack and Packer servers go to the second pass, which applies the
    # ownership and age checks; the minion filter above is a substring
    # match and can also select them.
    if [[ "$server_name" =~ $packer_server_regex ]] || \
            { [[ ${#silos[@]} -gt 0 ]] && is_stack_server_name "$server_name"; }; then
        continue
    fi

    # jenkins_urls intentionally needs globbing to be passed as separate params.
    # shellcheck disable=SC2153,SC2086
    if minion_in_jenkins "$server_name" $jenkins_urls; then
        if [[ "$DEBUG" == "true" ]]; then
            echo "INFO: Server $server_name (ID: $server_id) is in use, skipping"
        fi
        continue
    else
        if [[ "$DEBUG" == "true" ]]; then
            echo "INFO: Deleting orphaned server: $server_name (ID: $server_id)"
        fi

        # Check if server is old enough (15 minutes minimum)
        age_rc=0
        is_server_old_enough "$server_id" 15 || age_rc=$?
        if [[ $age_rc -eq 0 ]]; then
            # Use OpenStack CLI directly instead of lftools to avoid duplicate name issues
            if openstack --os-cloud "$os_cloud" server delete "$server_id" 2>&1; then
                deleted_servers+=("$server_name")
                ((deleted_count++)) || true
                if [[ "$DEBUG" == "true" ]]; then
                    echo "INFO: Successfully deleted server $server_name (ID: $server_id)"
                fi
            else
                exit_code=$?
                if [[ "$DEBUG" == "true" ]]; then
                    echo "⚠️  Warning: Failed to delete server $server_name (ID: $server_id) (exit code: $exit_code)"
                    echo "   Server may have already been deleted"
                fi
                # Don't fail entire cleanup if one server fails
            fi
        elif [[ $age_rc -eq 1 ]]; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "INFO: Server $server_name (ID: $server_id) is too new (< 15 minutes), skipping"
            fi
        fi
    fi
done

# Second pass: stack and Packer servers, which the first pass skips.
#  - Heat stack servers (<silo>-<n>-<n>-...) left behind after their stack
#    was deleted; only removed when no existing stack, in any status,
#    references them. Servers of failed stacks are left to the stack
#    cleanup, which deletes them through Heat with the stack.
#  - Packer build instances (<distro>-<template>-<uuid>, with server
#    metadata ci_managed=yes) left behind by interrupted image builds.
# Both are only removed once older than ORPHAN_SERVER_AGE_HOURS.
orphan_age_minutes=$((orphan_age_hours * 60))

# Collect server IDs referenced by every existing Heat stack, whatever
# its status. If any lookup fails the ownership is unknown, so stack
# servers are skipped rather than risked. Without silos there are no
# stack servers to check.
stack_lookup_ok=true
stack_owned_ids=""
if [[ ${#silos[@]} -gt 0 ]]; then
    # Heat returns one page per request; page with --marker until a
    # short page shows every stack has been listed. --hidden includes
    # stacks carrying an operator-configured hidden tag.
    stack_page_size=100
    stack_ids=""
    marker=""
    while true; do
        marker_args=()
        if [[ -n "$marker" ]]; then
            marker_args=(--marker "$marker")
        fi
        if ! page=$(openstack --os-cloud "$os_cloud" stack list --hidden \
                --limit "$stack_page_size" "${marker_args[@]}" -f value -c ID); then
            stack_lookup_ok=false
            break
        fi
        page_count=0
        for stack_id in $page; do
            stack_ids+=" $stack_id"
            marker=$stack_id
            ((page_count++)) || true
        done
        if [[ $page_count -lt $stack_page_size ]]; then
            break
        fi
    done
    if [[ "$stack_lookup_ok" == "true" ]]; then
        for stack_id in $stack_ids; do
            if ! ids=$(openstack --os-cloud "$os_cloud" stack resource list \
                    --nested-depth 5 --filter type=OS::Nova::Server \
                    -f value -c physical_resource_id "$stack_id"); then
                stack_lookup_ok=false
                break
            fi
            stack_owned_ids+=" ${ids//$'\n'/ }"
        done
    fi
fi
if [[ "$stack_lookup_ok" != "true" ]]; then
    echo "::warning::Could not list Heat stack resources; skipping stack server cleanup"
fi

if ! all_servers_out=$(openstack --os-cloud "$os_cloud" server list -f value -c "ID" -c "Name"); then
    echo "::error::Could not list servers for orphaned server cleanup"
    exit 1
fi
ALL_SERVERS=()
if [[ -n "$all_servers_out" ]]; then
    mapfile -t ALL_SERVERS <<< "$all_servers_out"
fi
for server_line in "${ALL_SERVERS[@]}"; do
    server_id=$(echo "$server_line" | awk '{print $1}')
    server_name=$(echo "$server_line" | awk '{$1=""; print $0}' | sed 's/^ //')

    # Only stack and Packer names are candidates here. Jenkins minions
    # (<prefix>-<template>-<n>) match neither pattern, and servers the
    # first pass deleted are absent from this later listing.
    if [[ ${#silos[@]} -gt 0 ]] && is_stack_server_name "$server_name"; then
        if [[ "$stack_lookup_ok" != "true" ]]; then
            continue
        fi
        if [[ " $stack_owned_ids " == *" $server_id "* ]]; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "INFO: Server $server_name (ID: $server_id) belongs to an existing stack, skipping"
            fi
            continue
        fi
    elif [[ "$server_name" =~ $packer_server_regex ]]; then
        if ! is_ci_managed "$server_id"; then
            if [[ "$DEBUG" == "true" ]]; then
                echo "INFO: Server $server_name (ID: $server_id) lacks ci_managed=yes metadata, skipping"
            fi
            continue
        fi
    else
        continue
    fi

    age_rc=0
    is_server_old_enough "$server_id" "$orphan_age_minutes" || age_rc=$?
    if [[ $age_rc -ne 0 ]]; then
        # rc 2 (age unknown) is already reported by the helper
        if [[ $age_rc -eq 1 && "$DEBUG" == "true" ]]; then
            echo "INFO: Server $server_name (ID: $server_id) is newer than ${orphan_age_hours}h, skipping"
        fi
        continue
    fi

    if openstack --os-cloud "$os_cloud" server delete "$server_id" 2>&1; then
        deleted_servers+=("$server_name")
        ((deleted_count++)) || true
    else
        echo "⚠️  Warning: Failed to delete orphaned server $server_name (ID: $server_id)"
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
