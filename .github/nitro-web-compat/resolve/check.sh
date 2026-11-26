#!/usr/bin/env bash
# Run with private output redirected by the caller. Docker receives an empty
# build context. The resolver mounts the inputs read-only and queries RubyGems.
set -euo pipefail
snapshot=$1
candidate=$2
scripts=$(cd "$(dirname "$0")" && pwd)
ruby_version=$(cat "$snapshot/.ruby-version")
bundler_version=$(awk '/^BUNDLED WITH$/ {getline; print $1}' "$snapshot/Gemfile.lock")
[[ $ruby_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $bundler_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
docker build --quiet --build-arg RUBY_VERSION="$ruby_version" --build-arg BUNDLER_VERSION="$bundler_version" \
  -t nitro-web-compat-toolchain - < "$scripts/Dockerfile" || exit 1
docker run --rm --cap-drop ALL --security-opt=no-new-privileges \
  --user "$(id -u):$(id -g)" --tmpfs /work:mode=1777 -e HOME=/work -e BUNDLE_APP_CONFIG=/work/.bundle \
  -v "$snapshot:/snapshot:ro" -v "$candidate:/candidate.json:ro" -v "$scripts:/verifier:ro" \
  nitro-web-compat-toolchain ruby /verifier/resolve.rb /snapshot /candidate.json
