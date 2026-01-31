# ☁️ OpenStack Cron Cleanup Action

<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- SPDX-FileCopyrightText: 2025 The Linux Foundation -->

Automated cleanup of orphaned OpenStack cloud resources via GitHub Actions.

## Overview

This action performs hourly cleanup of orphaned resources in OpenStack clouds:

- 🗑️ Kubernetes clusters
- 🗑️ Heat stacks
- 🗑️ Server instances
- 🗑️ Network ports
- 🗑️ Volumes
- 🛡️ Protects in-use images
- 🗑️ Removes old images

## Usage

### Basic Usage

```yaml
- uses: askb/openstack-cron-action@main
  with:
    openstack_cloud: 'vex'
    clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}
    jenkins_urls: 'https://jenkins.example.org/releng https://jenkins.example.org/sandbox'
```

### Using Repository Variables (Recommended)

```yaml
- uses: askb/openstack-cron-action@main
  with:
    openstack_cloud: ${{ vars.OPENSTACK_CLOUD || 'vex' }}
    clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}
    jenkins_urls: ${{ vars.JENKINS_URLS || '' }}
    failure_notification_email: ${{ vars.FAILURE_NOTIFICATION_EMAIL || '' }}
```

### Full Configuration

```yaml
- uses: askb/openstack-cron-action@main
  with:
    # Required
    openstack_cloud: 'vex'
    clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}

    # Optional - Jenkins integration
    jenkins_urls: 'https://jenkins.example.org/releng https://jenkins.example.org/sandbox'

    # Optional - Cleanup flags (all default to 'true')
    cleanup_k8s_clusters: 'true'
    cleanup_stacks: 'true'
    cleanup_servers: 'true'
    cleanup_ports: 'true'
    cleanup_volumes: 'true'
    protect_images: 'true'
    cleanup_images: 'true'

    # Optional - Parameters
    image_cleanup_age: '30'  # days
    port_cleanup_age: '30 minutes ago'
    python_version: '3.11'
    build_timeout: '10'  # minutes
```

## Inputs

### Required Inputs

| Input | Description | Example |
|-------|-------------|---------|
| `openstack_cloud` | OpenStack cloud name from clouds.yaml | `vex` |
| `clouds_yaml` | OpenStack clouds.yaml configuration | See below |

**Default for `clouds_yaml`**: `${{ secrets.OPENSTACK_CLOUDS_YAML }}`
(base64 encoded)

### Optional Inputs

#### Jenkins Integration

| Input | Description | Default |
|-------|-------------|---------|
| `jenkins_urls` | Space-separated list of Jenkins URLs to check for active builds | `''` |

#### Cleanup Control Flags

| Input | Description | Default |
|-------|-------------|---------|
| `cleanup_k8s_clusters` | Enable K8s cluster cleanup | `true` |
| `cleanup_stacks` | Enable OpenStack stack cleanup | `true` |
| `cleanup_servers` | Enable server/instance cleanup | `true` |
| `cleanup_ports` | Enable port cleanup | `true` |
| `cleanup_volumes` | Enable volume cleanup | `true` |
| `protect_images` | Enable protection of in-use images | `true` |
| `cleanup_images` | Enable old image cleanup | `true` |

#### Cleanup Parameters

| Input | Description | Default |
|-------|-------------|---------|
| `image_cleanup_age` | Age in days for image cleanup | `30` |
| `port_cleanup_age` | Age for port cleanup | `30 minutes ago` |
| `python_version` | Python version to use | `3.11` |
| `build_timeout` | Build timeout in minutes | `10` |

#### Notification Parameters

| Input | Description | Default |
|-------|-------------|---------|
| `failure_notification_email` | Email address(es) to notify on failure (comma-separated) | `''` (no email) |
| `failure_notification_prefix` | Email subject prefix for failure notifications | `[OpenStack Cleanup]` |

## Outputs

| Output | Description |
|--------|-------------|
| `cleanup_summary` | Summary of cleanup operations performed |
| `resources_cleaned` | Number of resources cleaned up |
| `cleanup_status` | Overall cleanup status (success/failure) |

## Scheduled Workflow Example

### Option 1: Using Repository Variables (Recommended)

For project-agnostic deployments, use repository variables to avoid hard-coding project-specific values:

Create `.github/workflows/openstack-cleanup.yaml`:

```yaml
---
name: OpenStack Cleanup

on:
  schedule:
    # Run every hour
    - cron: '0 * * * *'
  workflow_dispatch:
    inputs:
      openstack_cloud:
        description: 'OpenStack cloud name'
        required: false
        default: 'vex'

jobs:
  cleanup:
    runs-on: ubuntu-latest
    timeout-minutes: 10

    steps:
      - name: Run OpenStack cleanup
        uses: askb/openstack-cron-action@main
        with:
          openstack_cloud: ${{ inputs.openstack_cloud || vars.OPENSTACK_CLOUD || 'vex' }}
          clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}
          jenkins_urls: ${{ vars.JENKINS_URLS || '' }}
          failure_notification_email: ${{ vars.FAILURE_NOTIFICATION_EMAIL || '' }}
          failure_notification_prefix: ${{ vars.NOTIFICATION_PREFIX || '[OpenStack Cleanup]' }}
```

**Set these repository variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Example Value | Description |
|----------|---------------|-------------|
| `JENKINS_URLS` | `https://jenkins.example.org/releng https://jenkins.example.org/sandbox` | Jenkins URLs to check |
| `FAILURE_NOTIFICATION_EMAIL` | `releng@example.org` | Email for failure alerts |
| `NOTIFICATION_PREFIX` | `[MyProject]` | Email subject prefix |
| `OPENSTACK_CLOUD` | `vex` | Cloud name (optional) |

**Using GitHub CLI:**

```bash
gh variable set JENKINS_URLS \
  --body "https://jenkins.example.org/releng https://jenkins.example.org/sandbox" \
  --repo yourorg/yourrepo

gh variable set FAILURE_NOTIFICATION_EMAIL \
  --body "releng@example.org" \
  --repo yourorg/yourrepo

gh variable set NOTIFICATION_PREFIX \
  --body "[MyProject]" \
  --repo yourorg/yourrepo
```

### Option 2: Direct Action Reference

For simpler deployments or when hard-coding values is acceptable:

```yaml
---
name: OpenStack Cleanup

on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:

jobs:
  cleanup:
    runs-on: ubuntu-latest
    timeout-minutes: 10

    steps:
      - name: Run OpenStack cleanup
        uses: askb/openstack-cron-action@main
        with:
          openstack_cloud: 'vex'
          clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}
          jenkins_urls: 'https://jenkins.example.org/releng'
          failure_notification_email: 'releng@example.org'
```

## Secrets Setup

### Creating the clouds.yaml Secret

1. Create your `clouds.yaml` file:

   ```yaml
   clouds:
     vex:
       auth:
         auth_url: https://api.openstack.example.org:5000/v3
         username: your-username
         password: your-password
         project_id: your-project-id
         user_domain_name: Default
         project_domain_name: Default
       region_name: ca-ymq-1
   ```

2. Base64 encode it:

   ```bash
   base64 -w 0 < clouds.yaml
   ```

3. Add as GitHub Secret named `OPENSTACK_CLOUDS_YAML`

## Cleanup Operations

### 1. K8s Clusters (`cleanup_k8s_clusters`)

- Identifies orphaned Kubernetes clusters
- Checks Jenkins for active builds using the cluster
- Removes clusters not in active use

### 2. Stacks (`cleanup_stacks`)

- Identifies orphaned Heat stacks
- Checks Jenkins for active builds using the stack
- Removes stacks not in active use

### 3. Servers (`cleanup_servers`)

- Identifies orphaned server instances
- Checks Jenkins for active minions
- Removes servers not registered in Jenkins

### 4. Ports (`cleanup_ports`)

- Identifies orphaned network ports
- Removes ports older than configured age (default: 30 minutes)

### 5. Volumes (`cleanup_volumes`)

- Identifies available (unattached) volumes
- Removes volumes not in use

### 6. Image Protection (`protect_images`)

- Identifies CI-managed images (prefixed with "ZZCI - ")
- Sets protection flag to prevent accidental deletion

### 7. Old Images (`cleanup_images`)

- Identifies images older than configured age (default: 30 days)
- Removes old, unprotected images

## Requirements

- OpenStack cloud with API access
- Valid `clouds.yaml` configuration
- Python 3.11+ (automatically installed)
- Dependencies (automatically installed):
  - `lftools[openstack]`
  - `python-openstackclient`
  - `python-heatclient`
  - `python-magnumclient`
  - `kubernetes`
  - `niet`
  - `yq`

## Jenkins Integration

When `jenkins_urls` is provided, the action will:

1. Check each Jenkins URL for active builds
2. Identify resources in use by active builds
3. Skip cleanup of resources in active use
4. Only clean up truly orphaned resources

This prevents accidental deletion of resources needed by running jobs.

## Best Practices for Reusability

### Use Repository Variables

For project-agnostic deployments that can be shared across multiple projects:

**DO** ✅:

- Use `vars.JENKINS_URLS` instead of hard-coding Jenkins URLs
- Use `vars.FAILURE_NOTIFICATION_EMAIL` for project-specific notifications
- Use repository variables for any project-specific configuration

**DON'T** ❌:

- Hard-code project-specific values in workflow files
- Embed organization-specific Jenkins URLs directly
- Hard-code notification email addresses

### Example: Multi-Project Setup

**Project A (OpenDaylight)**:

```bash
gh variable set JENKINS_URLS \
  --body "https://jenkins.opendaylight.org/releng https://jenkins.opendaylight.org/sandbox" \
  --repo opendaylight/releng-builder

gh variable set FAILURE_NOTIFICATION_EMAIL \
  --body "releng+ODL@linuxfoundation.org" \
  --repo opendaylight/releng-builder
```

**Project B (ONAP)**:

```bash
gh variable set JENKINS_URLS \
  --body "https://jenkins.onap.org/ci" \
  --repo onap/ci-management

gh variable set FAILURE_NOTIFICATION_EMAIL \
  --body "onap-releng@lists.onap.org" \
  --repo onap/ci-management
```

**Same workflow file works for both!** No modifications needed.

### Workflow Design Patterns

**Standalone Scheduled Job** (This action):

- Uses `schedule` trigger for automatic hourly runs
- Uses `workflow_dispatch` for manual testing
- Does NOT use `workflow_call` (not called by other workflows)
- Independent from Gerrit integration

```yaml
on:
  schedule:
    - cron: '0 * * * *'
  workflow_dispatch:
```

**Reusable Workflow** (If you need to call from other workflows):

- Would use `workflow_call` instead
- Not applicable for this standalone cleanup job

## Troubleshooting

### Error: Cloud 'xxx' not found in clouds.yaml

**Solution**: Ensure your `clouds.yaml` secret contains the specified cloud name.

### Error: Authentication failure

**Solution**: Verify your OpenStack credentials in `clouds.yaml` are correct.

### Cleanup not removing resources

**Solution**:

- Check that cleanup flags are set to `true`
- Verify resources meet age requirements
- Check Jenkins integration isn't protecting resources

### Timeout errors

**Solution**: Increase `build_timeout` input if cleanup takes longer than 10 minutes.

## Contributing

See [CONTRIBUTING.md](../../CONTRIBUTING.md) for development setup and guidelines.

## License

Apache-2.0 - See [LICENSE](LICENSE) for details.

## Support

- **Issues**: [GitHub Issues](https://github.com/lfit/lfreleng-actions/issues)
- **Documentation**: This README
- **Source**: [GitHub Repository](https://github.com/lfit/lfreleng-actions)

## Related

- [packer-build-action](../packer-build-action/) - Build OpenStack images
- [lftools Documentation](https://docs.releng.linuxfoundation.org/projects/lftools/)
- [OpenStack CLI](https://docs.openstack.org/python-openstackclient/latest/)

---

**Maintained by**: The Linux Foundation Release Engineering Team

## Email Notifications

### Configuring Failure Notifications

The action supports email notifications on failure, matching the Jenkins behavior.

**In the action inputs**:

```yaml
- uses: lfit/lfreleng-actions/openstack-cron-action@main
  with:
    openstack_cloud: 'vex'
    clouds_yaml: ${{ secrets.OPENSTACK_CLOUDS_YAML }}
    failure_notification_email: 'releng+ODL@linuxfoundation.org'
    failure_notification_prefix: '[releng]'
```

**In the caller workflow** (builder-new):
The workflow includes an email notification step that sends emails on failure using the `dawidd6/action-send-mail` action.

**Required Secrets** (in calling repository):

- `SMTP_USERNAME` - SMTP authentication username
- `SMTP_PASSWORD` - SMTP authentication password
- `OPENSTACK_CLOUDS_YAML` - OpenStack credentials

**Email Content**:

- Subject: `[releng] repo-name - OpenStack Cleanup - Build #X - FAILED`
- Body: Includes repository, workflow, run details, and link to logs
- Recipients: Configurable via `failure_notification_email` input

**Default Behavior**:

- Notifications sent **only on failure**
- No emails sent on success
- Matches Jenkins `global-jjb-email-notification` behavior

## Debug Mode

By default, the action runs in quiet mode with minimal output. To enable verbose debug logging:

```yaml
- uses: askb/openstack-cron-action@main
  with:
    enable_debug: true  # Enable verbose debug logging
    # ... other inputs
```

**Debug mode output**: Shows detailed information about each operation
**Quiet mode output** (default): Shows only summaries (e.g.,
"✅ Deleted 3 servers: prd-123, snd-456, bastion-gh-789")

## Cleanup Summary

The action automatically generates a cleanup summary that appears in the
GitHub Actions UI:

```markdown
### 🧹 OpenStack Cleanup Summary

**Cloud**: vex
**Status**: ✅ Completed
**Timestamp**: 2026-01-20 08:00:00 UTC

#### Resources Cleaned
- 🔄 K8s Clusters: 0 deleted
- 📚 Heat Stacks: 1 deleted
- 🖥️ Servers: 3 deleted
- 🔌 Ports: 8 deleted
- 💾 Volumes: 2 deleted
- 🛡️ Images Protected: 150 images
- 🗑️ Old Images: 5 deleted

**Total Resources Cleaned**: 19
```
