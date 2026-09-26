#!/usr/bin/env bash
# Push the images tagged by scripts/build-images.sh to their registry.
#
# Deliberately separate from build-images.sh (operator request 2026-09-09):
# building/tagging is safe to run anytime, pushing is a one-way publish and
# should be an explicit, reviewable step.
#
# This script never logs in or handles credentials — run
#   podman login docker.io
# yourself first (or `podman login <registry>` for a different registry). On GitHub Actions the workflow
# logs in with docker/login-action and sets CONTAINER_ENGINE=docker.
#
# Inside GitHub Actions (GITHUB_ACTIONS is set) and with cosign + trivy installed, every pushed image is
# also signed keylessly (Sigstore, via the job's OIDC token) and gets a CycloneDX SBOM attached as a
# cosign attestation, both against the registry digest that was just pushed. Anywhere else that step is
# skipped, so a local push still works.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENGINE="${CONTAINER_ENGINE:-podman}"
TAG_FILE="scripts/.last-image-tag"
if [ ! -s "${TAG_FILE}" ]; then
  echo "No tags recorded at ${TAG_FILE}. Run scripts/build-images.sh first." >&2
  exit 1
fi

sign_and_attest() {
  local image="$1" repo digests digest_ref sbom

  if [ -z "${GITHUB_ACTIONS:-}" ] || ! command -v cosign >/dev/null 2>&1; then
    echo "  (skipping cosign signing: it only runs inside GitHub Actions, with cosign installed)"
    return 0
  fi
  if ! command -v trivy >/dev/null 2>&1; then
    echo "!! trivy is required to generate the SBOM that gets attached to ${image}" >&2
    return 1
  fi

  # Sign the digest that was actually pushed, not the mutable tag.
  repo="${image%%:*}"
  digests="$("${ENGINE}" inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${image}")"
  digest_ref="$(grep -m 1 "^${repo}@" <<<"${digests}" || true)"
  if [ -z "${digest_ref}" ]; then
    echo "!! Could not resolve the pushed digest of ${image}" >&2
    return 1
  fi

  echo "--- cosign sign: ${digest_ref} ---"
  cosign sign --yes "${digest_ref}"

  echo "--- SBOM attestation (CycloneDX): ${digest_ref} ---"
  sbom="$(mktemp)"
  trivy image --format cyclonedx --output "${sbom}" "${image}"
  cosign attest --yes --type cyclonedx --predicate "${sbom}" "${digest_ref}"
  rm -f "${sbom}"
}

echo "About to push:"
cat "${TAG_FILE}"
echo ""

while IFS= read -r image; do
  [ -z "${image}" ] && continue
  echo "=================================================================="
  echo "Pushing ${image}"
  echo "=================================================================="
  "${ENGINE}" push "${image}"
  sign_and_attest "${image}"
done < "${TAG_FILE}"

echo ""
echo "All images pushed."
