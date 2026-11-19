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
#
# After an image has been pushed, signed and attested, <repository>:<X.Y>-latest (e.g. 5.0-latest) is pointed at
# the same image, in each repository. It is the one floating tag: the dated tag never changes, while the alias
# moves to the newest published build of the series. It is only moved for an image that was signed and attested
# (so, in practice, only by the GitHub Actions publish job), and it must end up with the same digest as the
# dated tag, so the signature and the SBOM apply to it unchanged.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

ENGINE="${CONTAINER_ENGINE:-podman}"
TAG_FILE="scripts/.last-image-tag"
if [ ! -s "${TAG_FILE}" ]; then
  echo "No tags recorded at ${TAG_FILE}. Run scripts/build-images.sh first." >&2
  exit 1
fi

# Set to 1 by sign_and_attest only when the image really was signed and its SBOM attached (it returns 0 as well
# when it skips signing outside GitHub Actions), so the series alias is never moved for an unsigned image.
signed=0

sign_and_attest() {
  local image="$1" repo digests digest_ref sbom
  signed=0

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
  signed=1
}

# Point <repository>:<X.Y>-latest at the image that was just pushed (see the header). Only a
# <X.Y.Z>-alpine-b<YYYYMMDD> release tag gets an alias.
move_series_alias() {
  local image="$1" repo tag alias count
  repo="${image%%:*}"
  tag="${image#*:}"

  if [[ ! "${tag}" =~ ^([0-9]+)\.([0-9]+)\.[0-9]+-alpine-b[0-9]{8}$ ]]; then
    echo "  (no series alias for ${image}: not a <X.Y.Z>-alpine-b<date> release tag)"
    return 0
  fi
  alias="${repo}:${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-latest"

  echo "--- series alias: ${alias} -> ${image} ---"
  "${ENGINE}" tag "${image}" "${alias}"
  "${ENGINE}" push "${alias}"

  # One image, two tags: they must resolve to the same digest, or the signature would not cover the alias.
  count="$("${ENGINE}" inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "${image}" | grep -c "^${repo}@" || true)"
  case "${count}" in
    1) ;;
    0) echo "!! WARNING: could not confirm that ${alias} has the same digest as ${image} (no RepoDigests)" >&2 ;;
    *)
      echo "!! ${alias} ended up with a different digest than ${image} (${count} digests): the signature does not cover it" >&2
      return 1
      ;;
  esac
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
  if [ "${signed}" = 1 ]; then
    move_series_alias "${image}"
  else
    echo "  (series alias not moved: ${image} was not signed and attested)"
  fi
done < "${TAG_FILE}"

echo ""
echo "All images pushed."
