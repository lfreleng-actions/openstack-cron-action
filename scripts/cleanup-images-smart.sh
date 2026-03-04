#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 The Linux Foundation
##############################################################################
# Smart image cleanup - Only removes unused images older than specified days
#
# This script:
# 1. Fetches cloud-images.rst and scans JJB configs from the source repo
# 2. Identifies images in active use
# 3. Lists images older than configured age (default: 180 days / 6 months)
# 4. UNSETS protected flag on old unused images (doesn't delete)
# 5. Regular cleanup will delete unprotected images on next run
##############################################################################

os_cloud="${OS_CLOUD:-vex}"
age_days="${OS_IMAGE_CLEANUP_AGE:-180}"
repo_url="${BUILDER_REPO_URL:-https://github.com/opendaylight/releng-builder}"
repo_name="${GITHUB_REPOSITORY:-opendaylight/releng-builder}"
DEBUG="${DEBUG:-false}"

if [[ "$DEBUG" == "true" ]]; then
    set -eux -o pipefail
    echo "---> Smart image cleanup (DEBUG MODE)"
else
    set -eu -o pipefail
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Smart cleanup for images older than $age_days days"

# Create temp directory
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Step 1: Fetch cloud-images.rst from repo
images_rst="$tmpdir/cloud-images.rst"
[[ "$DEBUG" == "true" ]] && echo "INFO: Fetching cloud-images.rst from $repo_url"

if curl -sfL -o "$images_rst" "${repo_url}/raw/master/docs/cloud-images.rst" || \
   curl -sfL -o "$images_rst" "${repo_url}/raw/main/docs/cloud-images.rst"; then
    [[ "$DEBUG" == "true" ]] && echo "INFO: Found cloud-images.rst"
else
    echo "⚠️  Could not fetch cloud-images.rst from repo, skipping smart cleanup"
    echo "unprotected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

# Step 2: Extract ONLY current/recommended image names from cloud-images.rst
# Note: cloud-images.rst contains historical inventory of ALL images ever built.
# Only entries BEFORE "Historical inventory:" are current/in-use references.
sed -n '1,/Historical inventory/p' "$images_rst" \
    | grep "^\* ZZCI" | sed 's/^\* //' | sort -u > "$tmpdir/images-in-rst.txt" || true
image_count_rst=$(wc -l < "$tmpdir/images-in-rst.txt")
[[ "$DEBUG" == "true" ]] && echo "INFO: Found $image_count_rst current images in cloud-images.rst"

# Step 3: Scan JJB configs for additional image references
[[ "$DEBUG" == "true" ]] && echo "INFO: Scanning JJB configs for image references"

# Clone repo to scan JJB configs (shallow clone for speed)
if git clone --depth 1 --single-branch "$repo_url" "$tmpdir/repo" &>/dev/null; then
    # Search for image names in JJB YAML files
    {
        find "$tmpdir/repo/jjb" -name "*.yaml" -o -name "*.yml" 2>/dev/null | while read -r file; do
            # Look for image references (various patterns)
            grep -oP '(image|builder-image|base-image|cloud-image):\s*["\x27]?ZZCI[^"\x27]*' "$file" 2>/dev/null || true
        done
    } | sed 's/.*ZZCI/ZZCI/' | sed "s/[\"' ]//g" | sort -u >> "$tmpdir/images-in-jjb.txt"

    image_count_jjb=$(wc -l < "$tmpdir/images-in-jjb.txt" 2>/dev/null || echo 0)
    [[ "$DEBUG" == "true" ]] && echo "INFO: Found $image_count_jjb additional images in JJB configs"
else
    [[ "$DEBUG" == "true" ]] && echo "WARN: Could not clone repo, using only cloud-images.rst"
    touch "$tmpdir/images-in-jjb.txt"
fi

# Combine all in-use images
cat "$tmpdir/images-in-rst.txt" "$tmpdir/images-in-jjb.txt" | sort -u > "$tmpdir/images-in-use.txt"
total_in_use=$(wc -l < "$tmpdir/images-in-use.txt")
[[ "$DEBUG" == "true" ]] && echo "INFO: Total images in use: $total_in_use"

# Step 4: List all old images (older than specified days)
cutoff_date=$(date -d "$age_days days ago" +%Y-%m-%d)
[[ "$DEBUG" == "true" ]] && echo "INFO: Looking for images older than $cutoff_date (${age_days} days)"

# Get all ZZCI images and extract date from image name
# Format: "ZZCI - <platform> - <type> - <arch> - YYYYMMDD-HHMMSS.mmm"
# Note: openstack image list --long does not include 'Created At' in JSON output
openstack --os-cloud "$os_cloud" image list \
    --long -f json \
    | python3 -c "
import json, sys, re
data = json.load(sys.stdin)
for img in data:
    name = img.get('Name', '')
    if name.startswith('ZZCI'):
        # Extract date from image name (YYYYMMDD pattern near end)
        match = re.search(r'(\d{4})(\d{2})(\d{2})-\d{6}', name)
        if match:
            date_str = f'{match.group(1)}-{match.group(2)}-{match.group(3)}'
            print(f'{name}\t{date_str}')
        elif '$DEBUG' == 'true':
            print(f'DEBUG: Cannot extract date from: {name}', file=sys.stderr)
" | while IFS=$'\t' read -r name created_date; do
        if [[ "$created_date" < "$cutoff_date" ]]; then
            echo "$name"
        fi
    done | sort -u > "$tmpdir/images-old.txt"

old_count=$(wc -l < "$tmpdir/images-old.txt")
[[ "$DEBUG" == "true" ]] && echo "INFO: Found $old_count images older than $age_days days"

# Step 5: Find images that are old AND not in use
# comm -23: lines only in file1 (old images), not in file2 (in-use images)
comm -23 <(sort "$tmpdir/images-old.txt") <(sort "$tmpdir/images-in-use.txt") \
    > "$tmpdir/images-to-unprotect.txt"

to_unprotect_count=$(wc -l < "$tmpdir/images-to-unprotect.txt")

if [[ $to_unprotect_count -eq 0 ]]; then
    echo "unprotected_count=0" >> "${GITHUB_OUTPUT:-/dev/null}"
    echo "✅ No unused old images found to unprotect"
    exit 0
fi

[[ "$DEBUG" == "true" ]] && echo "INFO: Found $to_unprotect_count images to unprotect"

# Step 6: Unset protected flag on identified images
unprotected_count=0
unprotected_images=()

while read -r image; do
    # Check protected and visibility status in a single API call
    read -r is_protected visibility < <(
        openstack --os-cloud "$os_cloud" image show "$image" \
            -f value -c protected -c visibility 2>/dev/null \
        || echo "False unknown"
    )

    needs_update=false

    if [[ "$is_protected" == "True" ]]; then
        [[ "$DEBUG" == "true" ]] && echo "INFO: Unsetting protected flag for: $image"
        openstack --os-cloud "$os_cloud" image set --unprotected "$image"
        needs_update=true
    fi

    if [[ "$visibility" == "shared" ]]; then
        [[ "$DEBUG" == "true" ]] && echo "INFO: Setting visibility to private for: $image"
        openstack --os-cloud "$os_cloud" image set --private "$image"
        needs_update=true
    fi

    if [[ "$needs_update" == "true" ]]; then
        unprotected_images+=("$image")
        ((unprotected_count++)) || true
    else
        [[ "$DEBUG" == "true" ]] && echo "INFO: Image already unprotected and private: $image"
    fi
done < "$tmpdir/images-to-unprotect.txt"

# Output for GitHub Actions
echo "unprotected_count=$unprotected_count" >> "${GITHUB_OUTPUT:-/dev/null}"

# Generate detailed summary
{
    echo "### 🧠 Smart Image Cleanup Report"
    echo ""
    echo "**Cleanup Criteria**: Images older than **${age_days} days** AND not in use"
    echo "**Source Repository**: \`$repo_name\`"
    echo "**Cutoff Date**: $cutoff_date"
    echo ""
    echo "#### Analysis Results"
    echo "- 📋 Images in \`cloud-images.rst\`: **$image_count_rst**"
    echo "- 📋 Images in JJB configs: **$image_count_jjb**"
    echo "- 🛡️ Total images in use: **$total_in_use**"
    echo "- 🕐 Old images (>${age_days} days): **$old_count**"
    echo "- 🗑️ Unused old images identified: **$to_unprotect_count**"
    echo ""
    echo "#### Action Taken"
    if [[ $unprotected_count -gt 0 ]]; then
        echo "✅ **Unprotected $unprotected_count image(s)** (protection flag removed)"
        echo ""
        echo "These images will be deleted on the next regular cleanup run:"
        for img in "${unprotected_images[@]}"; do
            echo "- \`$img\`"
        done
    else
        echo "✅ No images needed unprotection"
    fi
} >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

# Summary output (always shown)
if [[ $unprotected_count -gt 0 ]]; then
    echo "✅ Unprotected $unprotected_count unused image(s) older than $age_days days"
    [[ "$DEBUG" == "false" ]] && echo "   Images will be deleted on next regular cleanup run"
else
    echo "✅ No unused old images found"
fi
