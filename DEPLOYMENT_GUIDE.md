<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2025 The Linux Foundation
-->

# OpenStack Cron Action - Deployment Guide

## Issues Fixed

### Issue 1: clouds.yaml YAML Parsing Error

**Error**: `expected <block end>, but found ':'` at line 3
**Root Cause**:

- Heredoc template had leading spaces before `clouds:`
- GitHub Actions preserved these spaces, creating malformed YAML
**Fix**: Removed all leading spaces from heredoc content

### Issue 2: Invalid lftools Commands

**Error**: `Error: No such command 'cleanup'`
**Root Cause**: Scripts called non-existent lftools commands
**Fixes**:

- Stack: Changed `stack cleanup` → `stack delete-stale`
- Server: Implemented full Jenkins-checking logic (lftools only has `--days`)
- Port: Implemented age-based cleanup (no lftools port commands exist)

## Commits Ready to Push

1. **536e917** - Fix: Correct lftools commands and clouds.yaml template
2. **85bc381** - Fix: Remove leading spaces in clouds.yaml heredoc

## Deployment Steps

```bash
cd ~/git/github/lfreleng-actions/openstack-cron-action

# Push to remote
git push origin main

# Verify the push
git log origin/main --oneline -2
```

## Testing

After push, the next workflow run should:

1. ✅ Generate valid clouds.yaml without YAML parsing errors
2. ✅ Successfully call `lftools stack delete-stale`
3. ✅ Properly check Jenkins for active servers before deletion
4. ✅ Cleanup old ports using age-based filtering
5. ✅ Complete without command errors

## Verification

Monitor the next scheduled run at:
<https://github.com/opendaylight/releng-builder/actions/workflows/openstack-cron.yaml>

Expected outcome: All cleanup scripts complete successfully without errors.

## Rollback (if needed)

```bash
git reset --hard origin/main  # Reset to last known good state
git push origin main --force
```
