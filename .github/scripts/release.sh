#!/usr/bin/env bash
# Cuts releases and proposes the next one, driven by the changelog. Run by
# .github/workflows/release.yml after every push to main:
#
# 1. `release.sh release`: if the version on main has no tag yet, a release PR
#    has just merged, so publish a GitHub release for it, which pushes the tag
#    the gem release job runs on.
# 2. `release.sh propose`: if the changelog has Unreleased entries, make the
#    release edits, bumping the version by what those entries call for, and
#    describe the release PR, assigned to whoever merged PRs since the last
#    release. The workflow's create-pull-request step opens or refreshes it.
#
# `release.sh next` prints the version a release would get, and
# `release.sh prepare` makes the release edits in the working tree, both
# without touching GitHub.
set -euo pipefail
# Errors inside $(...) stop the script too, not just the substitution. Bash 4.4 and later, as on
# GitHub's runners; macOS's bash 3.2 lacks it, which only weakens a local `next` or `prepare`.
shopt -s inherit_errexit 2>/dev/null || true

# Repository specifics.

CHANGELOG=docs/CHANGELOG.md
VERSION_FILE=lib/nitro_intelligence/version.rb
REPO_URL=https://github.com/powerhome/nitro-intelligence.rb

current_version() {
  sed -n 's/.*VERSION = "\([^"]*\)".*/\1/p' "$VERSION_FILE"
}

tag_for() {
  echo "v$1-nitro_intelligence"
}

# The commit that last changed the version: the release commit to tag. Merge commits are compared
# with their first parent, so that one would count too, though main takes only squash merges.
release_commit() {
  git log -1 --first-parent --diff-merges=first-parent --no-patch --format=%H -G'VERSION = ' -- "$VERSION_FILE"
}

# bump_version_files OLD NEW LEVEL. Checks the lockfile before writing either file, so a failure
# leaves both untouched.
bump_version_files() {
  if ! grep -qxF "    nitro_intelligence ($1)" Gemfile.lock; then
    echo "::error::Gemfile.lock does not pin nitro_intelligence ($1), so it was not bumped." >&2
    return 1
  fi
  # The versions reach perl as data, never as part of its program.
  OLD_VERSION=$1 NEW_VERSION=$2 perl -pi -e \
    's/VERSION = "\Q$ENV{OLD_VERSION}\E"/VERSION = "$ENV{NEW_VERSION}"/' "$VERSION_FILE"
  OLD_VERSION=$1 NEW_VERSION=$2 perl -pi -e \
    's/^    nitro_intelligence \(\Q$ENV{OLD_VERSION}\E\)$/    nitro_intelligence ($ENV{NEW_VERSION})/' Gemfile.lock
}

# changelog_links OLD NEW: the link references that replace the Unreleased one.
changelog_links() {
  printf '[Unreleased]: %s/compare/%s...HEAD\n' "$REPO_URL" "$(tag_for "$2")"
  printf '[%s]: %s/compare/%s...%s\n' "$2" "$REPO_URL" "$(tag_for "$1")" "$(tag_for "$2")"
}

# Everything below is the same in every repository that uses this script.

# section NAME: the changelog entries under "## [NAME]", without the heading.
section() {
  awk -v name="$1" '
    /^## \[/ { if (found) exit; found = index(tolower($0), "## [" tolower(name) "]") == 1; next }
    /^\[[^]]+\]: / { next }
    found { print }
  ' "$CHANGELOG" | sed -e '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}'
}

# bump_level < NOTES: major, minor, patch or none, per Semantic Versioning. An entry is any text
# other than a heading, whether a list item or a paragraph, and a heading counts only when it has
# an entry under it.
bump_level() {
  # One pass, with no early-exiting reader in a pipe: under pipefail, `grep -q` closing a pipe
  # early fails the writer with SIGPIPE once the notes outgrow the pipe buffer.
  awk '
    /^### / { heading = tolower($2); gsub(/[^a-z]/, "", heading); next }
    /[^[:space:]]/ {
      entries = 1
      if (heading == "removed" || tolower($0) ~ /\*\*breaking/) major = 1
      if (heading ~ /^(added|changed|deprecated)$/) minor = 1
    }
    END { print major ? "major" : minor ? "minor" : entries ? "patch" : "none" }
  '
}

# checked_version: the current version, failing unless it is a semantic version, so that a
# version file the pattern above no longer matches stops the run instead of releasing "v".
checked_version() {
  local version
  version=$(current_version)
  if ! is_semver "$version"; then
    echo "::error::The version is \"$version\", which is not a semantic version." >&2
    return 1
  fi
  echo "$version"
}

# is_semver VERSION: whether VERSION is a semantic version, by the grammar at semver.org: numeric
# components without leading zeros, and prerelease and build identifiers of letters, digits and
# hyphens. Nothing else, so a version read from a file can be written back without escaping.
is_semver() {
  local id='[0-9A-Za-z-]+'
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-$id(\.$id)*)?(\+$id(\.$id)*)?$ ]]
}

# bump VERSION LEVEL
bump() {
  local major minor patch
  if ! is_semver "$1"; then
    echo "::error::\"$1\" is not a semantic version, so it cannot be bumped." >&2
    return 1
  fi
  IFS=. read -r major minor patch <<<"${1%%[-+]*}"
  case $2 in
    major) echo "$((major + 1)).0.0" ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
  esac
}

next_version() {
  local level version
  level=$(section Unreleased | bump_level)
  [[ $level != none ]] || return 0
  version=$(checked_version)
  bump "$version" "$level"
}

# prepare: makes the release edits in the working tree and prints the version.
prepare() {
  local old new level date
  old=$(checked_version)
  level=$(section Unreleased | bump_level)
  [[ $level != none ]] || return 0
  new=$(bump "$old" "$level")
  date=$(date -u +%F)
  bump_version_files "$old" "$new" "$level" || return 1
  if [[ $(current_version) != "$new" ]]; then
    echo "::error::The version is $(current_version) after bumping it to $new." >&2
    return 1
  fi
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
  version=$(checked_version)
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
  # The release creates the tag on GitHub. Tag this checkout too, so that propose() can list
  # the merges since it.
  git tag "$tag" "$sha"
}

# mergers SINCE_TAG: the people who merged PRs into main since that release, bots left out,
# most recent first and at most 10, GitHub's limit on assignees.
mergers() {
  if ! git rev-parse -q --verify "refs/tags/$1" >/dev/null; then
    echo "::warning::$1 is not tagged, so the release PR is assigned to whoever pushed." >&2
    return
  fi
  git rev-list "$1..HEAD" | while read -r sha; do
    gh api "repos/{owner}/{repo}/commits/$sha/pulls" --jq '.[] | select(.merged_at) | .number'
  done | awk '!seen[$0]++' | while read -r number; do
    gh api "repos/{owner}/{repo}/pulls/$number" --jq 'select(.merged_by.type == "User") | .merged_by.login'
  done | awk '!seen[$0]++ && count++ < 10'
}

# propose: makes the release edits for the Unreleased entries and describes the release PR for
# release.yml's create-pull-request step, as step outputs: `version`, `assignees`, and `body-path`,
# a file outside the checkout so that it is not committed. With nothing unreleased it makes no
# edits and no outputs, and that step closes any open release PR, since its branch no longer
# differs from main.
propose() {
  local old level version assignees body_path
  old=$(checked_version)
  level=$(section Unreleased | bump_level)
  version=$(prepare)
  if [[ -z $version ]]; then
    echo "Nothing unreleased in $CHANGELOG."
    return
  fi

  assignees=$(mergers "$(tag_for "$old")" | paste -sd, -)
  # The pusher stands in only when, like a merger, they are a person rather than an automation.
  if [[ -z $assignees && $GITHUB_ACTOR != *"[bot]" && $(gh api "users/$GITHUB_ACTOR" --jq .type) == User ]]; then
    assignees=$GITHUB_ACTOR
  fi

  body_path="$RUNNER_TEMP/release-pr.md"
  printf '%s\n\n%s\n\n## %s\n\n%s\n' \
    "Releases $version, a $level bump from $old for the changelog's Unreleased entries (**Breaking** or Removed: major; Added, Changed or Deprecated: minor; anything else: patch)." \
    "Merging this publishes the GitHub release $(tag_for "$version"), which starts the release. \`.github/workflows/release.yml\` rebuilds this PR from main after every merge, so make changelog fixes on main rather than here." \
    "$version" "$(section "$version")" >"$body_path"

  {
    echo "version=$version"
    echo "assignees=$assignees"
    echo "body-path=$body_path"
  } >>"$GITHUB_OUTPUT"
}

case ${1:-} in
  next) next_version ;;
  prepare) prepare ;;
  release) release ;;
  propose) propose ;;
  *)
    echo "usage: $0 next|prepare|release|propose" >&2
    exit 64
    ;;
esac
