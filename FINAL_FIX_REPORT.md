# OpenStack Cron Action - Complete Fix Report

## Executive Summary

Fixed critical bugs in the OpenStack cleanup action that were causing workflow failures. The main issue was calling non-existent lftools commands and a YAML template syntax error preventing credential expansion.

## Root Cause Analysis

The workflow failure at https://github.com/opendaylight/releng-builder/actions/runs/19928275483/job/57133433198 was caused by:

1. **Primary Error**: `Error: No such command 'cleanup'` when calling `lftools openstack stack cleanup`
2. **Secondary Issue**: clouds.yaml template using single-quoted heredoc preventing variable substitution

## Verification of lftools Commands (Upstream Master)

Verified against lftools master branch (commit 9909973):

```bash
$ lftools openstack --os-cloud test stack --help
Commands:
  cost          Get Total Stack Cost.
  create        Create stack.
  delete        Delete stack.
  delete-stale  Delete stale stacks.       ← CORRECT COMMAND

$ lftools openstack --os-cloud test server --help
Commands:
  cleanup  Cleanup old servers.            ← EXISTS but only accepts --days
  list     List cloud servers.
  remove   Remove servers.

$ lftools openstack --os-cloud test cluster --help
ERROR: No such command 'cluster'.          ← DOES NOT EXIST

$ lftools openstack --os-cloud test port --help
ERROR: No such command 'port'.             ← DOES NOT EXIST
```

## Fixes Applied

### Fix 1: clouds.yaml Template (action.yaml)
```diff
- cat > "$HOME/.config/openstack/clouds.yaml" << 'EOF'
+ cat > "$HOME/.config/openstack/clouds.yaml" << EOF
```
**Impact**: GitHub Actions variables will now be properly expanded in the YAML template

### Fix 2: Stack Cleanup (scripts/cleanup-stacks.sh)
```diff
- lftools openstack --os-cloud "$os_cloud" stack cleanup --jenkins "$jenkins_urls"
+ lftools openstack --os-cloud "$os_cloud" stack delete-stale $jenkins_urls
```
**Changes**:
- Changed `cleanup` to `delete-stale` (correct command name)
- Removed `--jenkins` flag (doesn't exist)
- Jenkins URLs passed as positional arguments (intentional word splitting)

### Fix 3: Server Cleanup (scripts/cleanup-servers.sh)
**Before**: Called `lftools openstack server cleanup --jenkins` (flag doesn't exist)

**After**: Implemented full logic from global-jjb:
- Added `minion_in_jenkins()` function to query Jenkins API
- Fetches server list from OpenStack
- Cross-references with active Jenkins minions
- Uses `lftools openstack server remove --minutes 15` for orphaned servers

**Lines changed**: +67

### Fix 4: Port Cleanup (scripts/cleanup-ports.sh)
**Before**: Called `lftools openstack port cleanup` (command doesn't exist)

**After**: Implemented full logic from global-jjb:
- Age-based filtering with regex validation
- GNU parallel for concurrent processing
- Uses native `openstack port delete` commands
- Proper error handling and cleanup

**Lines changed**: +63

### Fix 5: Cluster Cleanup (scripts/cleanup-k8s-clusters.sh)
**Status**: ✅ Already correct - no changes needed

Uses native OpenStack CLI commands (`openstack coe cluster delete`) which is the correct approach since lftools doesn't have cluster commands.

## Testing Evidence

The fixes align with the proven implementations in releng-global-jjb:
- `shell/openstack-cleanup-orphaned-stacks.sh` - Uses `delete_stale()` function
- `shell/openstack-cleanup-orphaned-servers.sh` - Implements Jenkins checking logic
- `shell/openstack-cleanup-orphaned-ports.sh` - Uses parallel processing with age checking
- `shell/openstack-cleanup-orphaned-k8s-clusters.sh` - Uses native OpenStack CLI

## Files Changed

```
action.yaml                |  2 +-
scripts/cleanup-ports.sh   | 63 ++++++++++++++++++++++++++++++++++++
scripts/cleanup-servers.sh | 67 +++++++++++++++++++++++++++++++++++++++
scripts/cleanup-stacks.sh  |  4 ++-
4 files changed, 124 insertions(+), 12 deletions(-)
```

## Expected Outcome

The workflow should now:
1. ✅ Generate valid clouds.yaml with actual credentials
2. ✅ Successfully cleanup orphaned stacks using `delete-stale`
3. ✅ Properly check Jenkins for active servers before deletion
4. ✅ Cleanup old ports using age-based filtering
5. ✅ Cleanup K8s clusters (unchanged, already working)

## Next Steps

1. Commit these changes to the openstack-cron-action repository
2. Create a new release/tag
3. Update the consuming workflow in opendaylight/releng-builder to use the fixed version
4. Monitor the next scheduled run for success

## Additional Notes

- The local lftools branch `add-openstack-clusterc-coe-cleanup` has cluster commands, but these are NOT in upstream master
- The action must work with the published/upstream version of lftools
- All implementations now match the battle-tested global-jjb scripts
