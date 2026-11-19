#!/usr/bin/env bash
# Tests for scripts/push-images.sh that need no registry, no images and no network: how the series alias
# (<X.Y>-latest, e.g. 5.0-latest) is moved. The container engine, cosign and trivy are stand-ins that record the
# calls they receive, so each case is checked against exactly what the script asked for.
#
# push-images.sh runs from a throw-away copy of scripts/, so the real scripts/.last-image-tag (the record of your
# last local build) is never touched. GitHub Actions runs this in the verify job, before the images are built.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

pass=0
failed=0
ok()  { pass=$((pass + 1)); echo "  ok   - $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL - $1"; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

SERVER="tamacat/zabbix-server-mysql"
WEB="tamacat/zabbix-web-nginx-mysql"

# make_case <name> <image tag>... — a copy of push-images.sh, the tags it is to push, and the stand-ins.
make_case() {
  local d="${WORK}/$1"
  shift
  mkdir -p "${d}/bin" "${d}/repo/scripts"
  cp scripts/push-images.sh "${d}/repo/scripts/push-images.sh"
  printf '%s\n' "$@" > "${d}/repo/scripts/.last-image-tag"
  : > "${d}/calls.log"

  # The engine: records every call, and answers `inspect` with the digest(s) the "registry" holds for the
  # repository of the image asked about (a second, different digest when FAKE_SECOND_DIGEST=1).
  cat > "${d}/bin/fakeengine" <<'EOF'
#!/usr/bin/env bash
echo "engine $*" >> "${CALLS}"
if [ "$1" = "inspect" ]; then
  image="${*: -1}"
  printf '%s@sha256:%s\n' "${image%%:*}" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  if [ "${FAKE_SECOND_DIGEST:-0}" = 1 ]; then
    printf '%s@sha256:%s\n' "${image%%:*}" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  fi
fi
exit 0
EOF
  cat > "${d}/bin/cosign" <<'EOF'
#!/usr/bin/env bash
echo "cosign $*" >> "${CALLS}"
exit 0
EOF
  # trivy writes the SBOM to the --output file; the script then hands that file to cosign attest.
  cat > "${d}/bin/trivy" <<'EOF'
#!/usr/bin/env bash
echo "trivy $*" >> "${CALLS}"
while [ "$#" -gt 0 ]; do
  [ "$1" = "--output" ] && : > "$2"
  shift
done
exit 0
EOF
  chmod +x "${d}/bin/"*
}

# run_case <name> <inside GitHub Actions: 1|0> [FAKE_SECOND_DIGEST: 1|0] — the output goes to <name>/out.log and
# the exit status to <name>/rc.
run_case() {
  local d="${WORK}/$1" actions=""
  [ "$2" = 1 ] && actions=true
  env CALLS="${d}/calls.log" PATH="${d}/bin:${PATH}" CONTAINER_ENGINE=fakeengine \
    GITHUB_ACTIONS="${actions}" FAKE_SECOND_DIGEST="${3:-0}" \
    bash "${d}/repo/scripts/push-images.sh" > "${d}/out.log" 2>&1
  echo $? > "${d}/rc"
}

rc() { cat "${WORK}/$1/rc"; }
# called <case> <call> — the stand-ins logged exactly this call
called() { grep -qxF -- "$2" "${WORK}/$1/calls.log"; }
# line_of <case> <call> — line number of the first logged call that equals <call>
line_of() { grep -nxF -- "$2" "${WORK}/$1/calls.log" | head -n 1 | cut -d: -f1; }

# --- 1. signed and attested images get their series alias ---------------------------------------------------
make_case signed "${SERVER}:5.0.47-alpine-b20261119" "${WEB}:5.0.47-alpine-b20261119"
run_case signed 1
if [ "$(rc signed)" = 0 ]; then ok "a signed publish succeeds"; else bad "a signed publish failed: $(tail -3 "${WORK}/signed/out.log")"; fi
for repo in "${SERVER}" "${WEB}"; do
  if called signed "engine tag ${repo}:5.0.47-alpine-b20261119 ${repo}:5.0-latest" \
     && called signed "engine push ${repo}:5.0-latest"; then
    ok "${repo}: 5.0.47 -> 5.0-latest is tagged and pushed"
  else
    bad "${repo}: the 5.0-latest alias was not tagged and pushed"
  fi
done

# --- 2. the alias moves only after the image is pushed, signed and attested --------------------------------
attest="$(grep -n '^cosign attest' "${WORK}/signed/calls.log" | head -n 1 | cut -d: -f1)"
latest="$(line_of signed "engine push ${SERVER}:5.0-latest")"
dated="$(line_of signed "engine push ${SERVER}:5.0.47-alpine-b20261119")"
if [ -n "${attest}" ] && [ -n "${latest}" ] && [ -n "${dated}" ] && [ "${dated}" -lt "${attest}" ] && [ "${attest}" -lt "${latest}" ]; then
  ok "the alias is pushed after the dated tag and after cosign attest"
else
  bad "order is wrong (dated push line=${dated:-none}, attest line=${attest:-none}, alias push line=${latest:-none})"
fi

# --- 3. outside GitHub Actions nothing is signed, so no alias is moved -------------------------------------
make_case local "${SERVER}:5.0.47-alpine-b20261119"
run_case local 0
if [ "$(rc local)" = 0 ] && called local "engine push ${SERVER}:5.0.47-alpine-b20261119" \
   && ! grep -q -- '-latest' "${WORK}/local/calls.log"; then
  ok "outside GitHub Actions the dated tag is pushed and no alias is moved"
else
  bad "outside GitHub Actions: unexpected calls: $(cat "${WORK}/local/calls.log" | tr '\n' ';')"
fi

# --- 4. the alias must have the same digest as the dated tag -----------------------------------------------
make_case mismatch "${SERVER}:5.0.47-alpine-b20261119"
run_case mismatch 1 1
if [ "$(rc mismatch)" != 0 ] && grep -q 'different digest' "${WORK}/mismatch/out.log"; then
  ok "an alias that ended up with another digest fails the publish"
else
  bad "a digest mismatch was not caught (exit $(rc mismatch))"
fi

# --- 5. only a <X.Y.Z>-alpine-b<date> release tag gets an alias ---------------------------------------------
make_case notrelease "${SERVER}:5.0.47-custom"
run_case notrelease 1
if [ "$(rc notrelease)" = 0 ] && ! grep -q -- '-latest' "${WORK}/notrelease/calls.log"; then
  ok "a tag that is not a release tag gets no alias"
else
  bad "a non-release tag was given an alias or the run failed: $(cat "${WORK}/notrelease/calls.log" | tr '\n' ';')"
fi

echo
echo "${pass} passed, ${failed} failed"
[ "${failed}" -eq 0 ]
