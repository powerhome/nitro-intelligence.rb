#!/usr/bin/env bash
set -euo pipefail

source_dir=$(cd "$1" && pwd)
scripts=$(cd "$(dirname "$0")" && pwd)
ruby_version=$(cat "$scripts/.ruby-version")
result=$(mktemp)
trap 'rm -f "$result"' EXIT

# Only this size-limited file crosses from candidate code to the trusted validator.
status=0
docker run --rm --read-only --network none --cap-drop ALL --security-opt=no-new-privileges \
  --user "$(id -u):$(id -g)" --cpus 1 --memory 256m --pids-limit 64 --ulimit fsize=65536:65536 \
  --tmpfs /tmp:size=16m,mode=1777 --log-driver none -e HOME=/tmp -w /candidate \
  -v "$source_dir:/candidate:ro" -v "$scripts/load_gemspec.rb:/loader.rb:ro" -v "$result:/metadata.json:rw" \
  "ruby:${ruby_version}-bookworm" timeout --signal=KILL 30s ruby /loader.rb /metadata.json >/dev/null 2>&1 || status=$?
case "$status" in
  0) python3 "$scripts/candidate.py" < "$result" ;;
  125|126|127) echo "Could not start the gemspec loader (Docker exit $status)." >&2; exit 1 ;;
  *) exit 2 ;; # The candidate could not be evaluated within the container limits.
esac
