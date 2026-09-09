#!/usr/bin/env bash
# Push the images tagged by scripts/build-images.sh to their registry.
#
# Deliberately separate from build-images.sh (operator request 2026-09-09):
# building/tagging is safe to run anytime, pushing is a one-way publish and
# should be an explicit, reviewable step.
#
# This script never logs in or handles credentials — run
#   podman login docker.io
# yourself first (or `podman login <registry>` for a different registry).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

TAG_FILE="scripts/.last-image-tag"
if [ ! -s "${TAG_FILE}" ]; then
  echo "No tags recorded at ${TAG_FILE}. Run scripts/build-images.sh first." >&2
  exit 1
fi

echo "About to push:"
cat "${TAG_FILE}"
echo ""

while IFS= read -r image; do
  [ -z "${image}" ] && continue
  echo "=================================================================="
  echo "Pushing ${image}"
  echo "=================================================================="
  podman push "${image}"
done < "${TAG_FILE}"

echo ""
echo "All images pushed."
