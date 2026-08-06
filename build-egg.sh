#!/usr/bin/env bash
# Builds egg-peers-node.json from install.sh, so the shell script stays
# editable and lintable instead of living as an escaped JSON string.
#
# Run this after any change to install.sh, then re-import the egg.
set -euo pipefail
cd "$(dirname "$0")"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

jq -n \
  --rawfile script install.sh \
  --slurpfile meta egg.meta.json \
  '$meta[0] | .scripts.installation.script = $script' \
  > egg-peers-node.json

echo "wrote egg-peers-node.json ($(wc -c < egg-peers-node.json) bytes)"
