#!/usr/bin/env bash
# Cuts releases and proposes the next one, driven by the changelog. Run by
# .github/workflows/release.yml after every push to main:
#
# 1. If the version on main has no tag yet, a release PR has just merged:
#    publish a GitHub release for it, which pushes the tag the gem release job
#    runs on.
# 2. If the changelog has Unreleased entries, open (or refresh) the one release
#    PR on $BRANCH, bumping the version by what those entries call for and
#    assigning whoever merged PRs since the last release.
#
# `release.sh next` prints the version a release would get, and
# `release.sh prepare` makes the release edits in the working tree, both
# without touching GitHub.
set -euo pipefail

# Repository specifics.

CHANGELOG=docs/CHANGELOG.md
VERSION_FILE=lib/nitro_intelligence/version.rb
REPO_URL=https://github.com/powerhome/nitro-intelligence.rb

current_version() {
  sed -n 's/.*VERSION = "\(.*\)".*/\1/p' "$VERSION_FILE"
}

tag_for() {
  echo "v$1-nitro_intelligence"
}

# The commit that last changed the version: the release commit to tag.
release_commit() {
  git log -1 --format=%H -G'VERSION = ' -- "$VERSION_FILE"
}

# bump_version_files OLD NEW LEVEL
bump_version_files() {
  perl -pi -e "s/VERSION = \"\Q$1\E\"/VERSION = \"$2\"/" "$VERSION_FILE"
  perl -pi -e "s/^    nitro_intelligence \(\Q$1\E\)\$/    nitro_intelligence ($2)/" Gemfile.lock
}

# changelog_links OLD NEW: the link references that replace the Unreleased one.
changelog_links() {
  printf '[Unreleased]: %s/compare/%s...HEAD\n' "$REPO_URL" "$(tag_for "$2")"
  printf '[%s]: %s/compare/%s...%s\n' "$2" "$REPO_URL" "$(tag_for "$1")" "$(tag_for "$2")"
}

# Everything below is the same in every repository that uses this script.

BRANCH=automated-release

# section NAME: the changelog entries under "## [NAME]", without the heading.
section() {
  awk -v name="$1" '
    /^## \[/ { if (found) exit; found = index(tolower($0), "## [" tolower(name) "]") == 1; next }
    /^\[[^]]+\]: / { next }
    found { print }
  ' "$CHANGELOG" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# bump_level < NOTES: major, minor, patch or none, per Semantic Versioning.
bump_level() {
  local notes
  notes=$(cat)
  if ! grep -qE '^[[:space:]]*[-*] ' <<<"$notes"; then
    echo none
  elif grep -qiE '^### Removed|\*\*Breaking' <<<"$notes"; then
    echo major
  elif grep -qE '^### (Added|Changed|Deprecated)' <<<"$notes"; then
    echo minor
  else
    echo patch
  fi
}

# bump VERSION LEVEL
bump() {
  local major minor patch
  IFS=. read -r major minor patch <<<"${1%%[-+]*}"
  case $2 in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
  esac
}

next_version() {
  local level
  level=$(section Unreleased | bump_level)
  [[ $level == none ]] || bump "$(current_version)" "$level"
}

# prepare: makes the release edits in the working tree and prints the version.
prepare() {
  local old new level date
  old=$(current_version)
  level=$(section Unreleased | bump_level)
  [[ $level != none ]] || return 0
  new=$(bump "$old" "$level")
  date=$(date -u +%F)
  bump_version_files "$old" "$new" "$level"
  LINKS=$(changelog_links "$old" "$new") awk -v heading="## [$new] - $date" '
    tolower($0) ~ /^## \[unreleased\]/ { print; print ""; print heading; next }
    tolower($0) ~ /^\[unreleased\]: / { print ENVIRON["LINKS"]; next }
    { print }
  ' "$CHANGELOG" >"$CHANGELOG.tmp"
  mv "$CHANGELOG.tmp" "$CHANGELOG"
  echo "$new"
}

# Publishes a GitHub release for the version on main if it has none yet.
release() {
  local version tag sha
  version=$(current_version)
  tag=$(tag_for "$version")
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "$tag is already released."
    return
  fi
  if ! grep -qF "## [$version]" "$CHANGELOG"; then
    echo "::error::$version has no tag and no section in $CHANGELOG, so it is not released."
    return 1
  fi
  sha=$(release_commit)
  section "$version" | gh release create "$tag" --target "$sha" --title "$tag" --notes-file -
  git tag "$tag" "$sha"
}

# mergers SINCE_TAG: the people who merged PRs into main since that release,
# bots left out.
mergers() {
  git rev-list "$1..HEAD" | while read -r sha; do
    gh api "repos/{owner}/{repo}/commits/$sha/pulls" --jq '.[] | select(.merged_at) | .number'
  done | sort -u | while read -r number; do
    gh api "repos/{owner}/{repo}/pulls/$number" --jq 'select(.merged_by.type == "User") | .merged_by.login'
  done | sort -u | head -n 10
}

# Opens the release PR, or refreshes the open one, from the changelog on main.
propose() {
  local old level open version notes body assignees bot_id
  old=$(current_version)
  level=$(section Unreleased | bump_level)
  open=$(gh pr list --head "$BRANCH" --base main --state open --json number --jq '.[0].number // empty')
  version=$(prepare)

  if [[ -z $version ]]; then
    echo "Nothing unreleased in $CHANGELOG."
    if [[ -n $open ]]; then
      gh pr close "$open" --comment "$CHANGELOG has nothing unreleased any more, so there is nothing to release."
      if git ls-remote --exit-code -q origin "refs/heads/$BRANCH" >/dev/null; then
        git push -q origin --delete "$BRANCH"
      fi
    fi
    return
  fi

  # Looked up before anything is pushed, so a failed lookup leaves no unassigned PR.
  assignees=$(mergers "$(tag_for "$old")" | paste -sd, -)
  if [[ -z $assignees && $GITHUB_ACTOR != *"[bot]" ]]; then
    assignees=$GITHUB_ACTOR
  fi

  bot_id=$(gh api "users/${APP_SLUG}%5Bbot%5D" --jq .id)
  git -c user.name="${APP_SLUG}[bot]" -c user.email="${bot_id}+${APP_SLUG}[bot]@users.noreply.github.com" \
    commit -q -am "Release $version"
  git push -q --force origin "HEAD:refs/heads/$BRANCH"

  notes=$(section "$version")
  printf -v body '%s\n\n%s\n\n## %s\n\n%s\n' \
    "Releases $version, a $level bump from $old for the changelog's Unreleased entries (**Breaking** or Removed: major; Added, Changed or Deprecated: minor; anything else: patch)." \
    "Merging this publishes the GitHub release $(tag_for "$version"), which starts the release. \`.github/workflows/release.yml\` rebuilds this PR from main after every merge, so make changelog fixes on main rather than here." \
    "$version" "$notes"

  if [[ -n $open ]]; then
    gh pr edit "$open" --title "Release $version" --body "$body"
  else
    open=$(gh pr create --head "$BRANCH" --base main --title "Release $version" --body "$body" | sed 's|.*/||')
  fi

  if [[ -n $assignees ]]; then
    gh pr edit "$open" --add-assignee "$assignees"
  fi
}

case ${1:-run} in
  next) next_version ;;
  prepare) prepare ;;
  run)
    release
    propose
    ;;
  *)
    echo "usage: $0 [run|next|prepare]" >&2
    exit 64
    ;;
esac
