#!/usr/bin/env bash
set -euo pipefail

# --- Configuration ---
WORKFLOW_DIR="${WORKFLOW_DIR:-.github/workflows}"
EXTRA_DIRS="${EXTRA_DIRS:-}"
FAIL_ON_ERROR="${FAIL_ON_ERROR:-false}"
PR_NUMBER="${PR_NUMBER:-}"
REPO="${REPO:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Collect all YAML files to scan
yaml_files=()

if [[ -d "$WORKFLOW_DIR" ]]; then
  while IFS= read -r -d '' f; do
    yaml_files+=("$f")
  done < <(find "$WORKFLOW_DIR" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
fi

IFS=',' read -ra extra_dirs <<< "$EXTRA_DIRS"
for dir in "${extra_dirs[@]}"; do
  dir="$(echo "$dir" | xargs)" # trim whitespace
  if [[ -n "$dir" && -d "$dir" ]]; then
    while IFS= read -r -d '' f; do
      yaml_files+=("$f")
    done < <(find "$dir" -type f \( -name '*.yml' -o -name '*.yaml' \) -print0)
  fi
done

if [[ ${#yaml_files[@]} -eq 0 ]]; then
  echo "No workflow YAML files found. Nothing to validate."
  exit 0
fi

echo "Scanning ${#yaml_files[@]} YAML file(s) for third-party action references..."

# --- Parse action references pinned to SHAs ---
# Matches lines like:  uses: owner/repo@<40-hex-char SHA>
# Also handles subpaths: owner/repo/path@<sha>
SHA_PATTERN='uses:[[:space:]]+([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)(/[^@]*)?\@([0-9a-fA-F]{40})'

declare -A seen_refs=()  # deduplicate owner/repo@sha
declare -A repo_shas=()  # owner/repo -> space-separated list of SHAs
invalid_refs=()

for file in "${yaml_files[@]}"; do
  while IFS= read -r line; do
    if [[ "$line" =~ $SHA_PATTERN ]]; then
      owner_repo="${BASH_REMATCH[1]}"
      sha="${BASH_REMATCH[3]}"
      ref_key="${owner_repo}@${sha}"

      if [[ "${seen_refs[$ref_key]:-}" == "1" ]]; then
        continue
      fi
      seen_refs[$ref_key]=1
      repo_shas[$owner_repo]+="  $sha"

      echo "  Found: ${ref_key} (in ${file})"
    fi
  done < "$file"
done

if [[ ${#seen_refs[@]} -eq 0 ]]; then
  echo "No third-party actions pinned to commit SHAs found."
  exit 0
fi

echo ""
echo "Validating ${#seen_refs[@]} unique action reference(s) across ${#repo_shas[@]} repository/repositories..."

# --- Validate each SHA against its repository (clone each repo only once) ---
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

for owner_repo in "${!repo_shas[@]}"; do
  echo ""
  echo "Cloning ${owner_repo} ..."

  clone_dir="${tmpdir}/${owner_repo//\//_}"
  repo_url="https://x-access-token:${GITHUB_TOKEN}@github.com/${owner_repo}.git"

  # Shallow clone is not sufficient for branch --contains, so we do a
  # bare clone which fetches all refs but skips the working tree.
  if ! git clone --bare --quiet "$repo_url" "$clone_dir" 2>/dev/null; then
    echo "  WARNING: Could not clone ${owner_repo}. Skipping."
    continue
  fi

  # Check all SHAs for this repository against the single clone
  read -ra shas <<< "${repo_shas[$owner_repo]}"
  for sha in "${shas[@]}"; do
    echo "  Checking ${owner_repo}@${sha} ..."
    if git -C "$clone_dir" branch -r --contains "$sha" &>/dev/null; then
      echo "  OK: SHA ${sha} is present in ${owner_repo}"
    else
      echo "  INVALID: SHA ${sha} is NOT contained in any branch of ${owner_repo}"
      invalid_refs+=("${owner_repo}@${sha}")
    fi
  done

  # Clean up clone immediately to save disk
  rm -rf "$clone_dir"
done

echo ""

# --- Report results ---
if [[ ${#invalid_refs[@]} -eq 0 ]]; then
  echo "All action SHAs validated successfully."
  exit 0
fi

echo "Found ${#invalid_refs[@]} action(s) with SHAs not owned by their repository:"
for ref in "${invalid_refs[@]}"; do
  echo "  - ${ref}"
done

# --- Comment on the PR ---
if [[ -n "$PR_NUMBER" && -n "$REPO" && -n "$GITHUB_TOKEN" ]]; then
  comment_body="## :warning: Commit SHA Validator — Invalid Action References\n\n"
  comment_body+="The following third-party actions are pinned to commit SHAs that **do not belong to any branch** in their repository. "
  comment_body+="This may indicate a supply-chain risk (e.g., a SHA from a fork or a deleted branch).\n\n"
  comment_body+="| Action | SHA |\n|---|---|\n"

  for ref in "${invalid_refs[@]}"; do
    owner_repo="${ref%%@*}"
    sha="${ref##*@}"
    comment_body+="| \`${owner_repo}\` | \`${sha}\` |\n"
  done

  comment_body+="\n**Recommendation:** Verify that each SHA corresponds to a tagged release or a commit on a maintained branch of the upstream repository.\n"

  echo "Commenting on PR #${PR_NUMBER}..."
  # Use the GitHub REST API to create a comment
  api_url="https://api.github.com/repos/${REPO}/issues/${PR_NUMBER}/comments"

  http_status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -d "$(jq -n --arg body "$(echo -e "$comment_body")" '{body: $body}')" \
    "$api_url")

  if [[ "$http_status" -ge 200 && "$http_status" -lt 300 ]]; then
    echo "PR comment posted successfully."
  else
    echo "WARNING: Failed to post PR comment (HTTP ${http_status})."
  fi
else
  echo "Not running in a PR context — skipping PR comment."
fi

if [[ "$FAIL_ON_ERROR" == "true" ]]; then
  echo "Failing workflow because invalid SHAs were found and fail-on-error is enabled."
  exit 1
fi
