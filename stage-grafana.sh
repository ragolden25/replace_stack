#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------
# CONFIG
# ------------------------------------------------------------
REPO_URL=https://github.com/grafana/grafana.git
REPO_MODULE="github.com/grafana/grafana"

STAGED_ROOT="/opt/ansible/staged/grafana"
GLOBAL_INVENTORY="/opt/ansible/staged/grafana/inventory.env"
BUILD_SYNC="/opt/ansible/build/grafana_stack/grafana/scripts/sync-latest-version.sh"

# ------------------------------------------------------------
# DETERMINE GRAFANA VERSION
# ------------------------------------------------------------
if [[ $# -ge 1 ]]; then
    GRAFANA_VERSION="$1"
else
    GRAFANA_VERSION="$(/opt/ansible/staged/grafana/scripts/detect_grafana_version.sh)"
fi

BASE_DIR="${STAGED_ROOT}/${GRAFANA_VERSION}"
SRC_DIR="${BASE_DIR}/src"
STAGED_DIR="${BASE_DIR}/staged"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/stage_grafana_${GRAFANA_VERSION}.log"
VERSION_INVENTORY="${BASE_DIR}/inventory.env"

mkdir -p "${SRC_DIR}" "${STAGED_DIR}" "${LOG_DIR}"

echo "=== Grafana ${GRAFANA_VERSION} Staging ===" | tee "${LOG_FILE}"

# ------------------------------------------------------------
# VERSION GATE
# ------------------------------------------------------------
# Only skip staging when the recorded version matches this run AND
# both binaries are actually present on disk. If either binary is
# missing, fall through and re-stage regardless of what inventory.env
# says — a partial/interrupted prior run can leave a stale inventory
# file behind that no longer reflects what's on disk.
if [[ -f "${VERSION_INVENTORY}" ]]; then
    # shellcheck disable=SC1090
    source "${VERSION_INVENTORY}"

    if [[ "${STAGED_GRAFANA_VERSION:-}" == "${GRAFANA_VERSION}" ]] \
       && [[ -f "${STAGED_DIR}/grafana-server" ]] \
       && [[ -f "${STAGED_DIR}/grafana-cli" ]]; then

        echo "--- Grafana ${GRAFANA_VERSION} already staged and valid ---" | tee -a "${LOG_FILE}"
        echo "--- Syncing into build structure ---" | tee -a "${LOG_FILE}"

        "${BUILD_SYNC}" "${GRAFANA_VERSION}" | tee -a "${LOG_FILE}"
        exit 0
    else
        echo "--- Inventory found for ${GRAFANA_VERSION} but binaries missing/incomplete; re-staging ---" | tee -a "${LOG_FILE}"
    fi
fi

echo "--- Staging required for Grafana ${GRAFANA_VERSION} ---" | tee -a "${LOG_FILE}"

# Remove and recreate the directories themselves rather than globbing
# their contents. `dir/*` does not match dotfiles (e.g. a leftover
# .git/ from an interrupted prior clone), so a glob-based cleanup can
# leave SRC_DIR non-empty; `git clone` then refuses to clone into it
# ("destination path already exists and is not an empty directory"),
# which — under `set -euo pipefail` — kills the whole script. This is
# almost certainly what "stops all work" when a version directory
# already exists.
rm -rf "${SRC_DIR:?}" "${STAGED_DIR:?}"
mkdir -p "${SRC_DIR}" "${STAGED_DIR}"

# ------------------------------------------------------------
# CLONE SOURCE
# ------------------------------------------------------------
echo "--- Cloning Grafana v${GRAFANA_VERSION} ---" | tee -a "${LOG_FILE}"
git clone --branch "v${GRAFANA_VERSION}" --depth 1 \
    "${REPO_URL}" \
    "${SRC_DIR}" 2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# RELOCATE BUILD CACHES
# ------------------------------------------------------------
export GOCACHE="/opt/ansible/go-cache"
export GOMODCACHE="/opt/ansible/go-mod"
export TMPDIR="/opt/ansible/tmp"

mkdir -p "$GOCACHE" "$GOMODCACHE" "$TMPDIR"

# ------------------------------------------------------------
# INSTALL UI DEPENDENCIES
# ------------------------------------------------------------
# Debian's yarnpkg package cannot be installed at all in an image that
# also has NodeSource's Node 22 (its own apt dependency is literally
# `nodejs (<21) | node-chalk`) — so it's not usable here regardless of
# install order. Fortunately Grafana vendors the exact Yarn release its
# build needs directly in its own repo: v12.4.11's .yarnrc.yml sets
# `yarnPath: .yarn/releases/yarn-4.11.0.cjs`, which lands in SRC_DIR
# the moment the clone above finishes. Running that file with `node`
# directly is functionally identical to `yarn <args>` for this project,
# needs no system-wide yarn/yarnpkg install, and never touches the
# network — the exact pinned version is already on disk. This also
# explains the earlier Corepack error: Corepack ignores yarnPath and
# manages its own version cache off the "packageManager" field, so it
# tried to fetch 4.11.0 from repo.yarnpkg.com even though the identical
# file was already sitting in the checkout.
# COREPACK_ENABLE_NETWORK=0 / COREPACK_ENABLE_DOWNLOAD_PROMPT=0 stay on
# as a defensive guard in case any postinstall script shells out to
# `yarn`/`corepack` indirectly; harmless either way since Corepack
# isn't invoked by the commands below.
echo "--- Installing Grafana UI dependencies ---" | tee -a "${LOG_FILE}"
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace \
  -e NODE_OPTIONS=--max_old_space_size=8000 \
  -e COREPACK_ENABLE_NETWORK=0 \
  -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  container-forge/debian13-node22:latest \
  bash -c '
    YARN_CJS="$(ls .yarn/releases/yarn-*.cjs 2>/dev/null | head -n1)"
    if [[ -z "${YARN_CJS}" ]]; then
      echo "ERROR: no vendored yarn release found under .yarn/releases/" >&2
      exit 1
    fi
    echo "--- Using vendored ${YARN_CJS} ---"
    node "${YARN_CJS}" install
  ' 2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# BUILD FRONTEND
# ------------------------------------------------------------
echo "--- Building Grafana frontend ---" | tee -a "${LOG_FILE}"
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace \
  -e NODE_OPTIONS=--max_old_space_size=8000 \
  -e NODE_ENV=production \
  -e COREPACK_ENABLE_NETWORK=0 \
  -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
  container-forge/debian13-node22:latest \
  bash -c '
    YARN_CJS="$(ls .yarn/releases/yarn-*.cjs 2>/dev/null | head -n1)"
    if [[ -z "${YARN_CJS}" ]]; then
      echo "ERROR: no vendored yarn release found under .yarn/releases/" >&2
      exit 1
    fi
    node "${YARN_CJS}" build
  ' 2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# BACKEND BUILD
# ------------------------------------------------------------
echo "--- Building Grafana backend ---" | tee -a "${LOG_FILE}"
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -v /opt/ansible/go-cache:/opt/go-cache \
  -v /opt/ansible/go-mod:/opt/go-mod \
  -v /opt/ansible/tmp:/opt/tmp \
  -w /workspace \
  -e GOCACHE=/opt/go-cache \
  -e GOMODCACHE=/opt/go-mod \
  -e TMPDIR=/opt/tmp \
  -e CGO_ENABLED=0 \
  -e GRAFANA_TAGS=oss \
  container-forge/debian13-go:latest \
  bash -c "make build-go" 2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# STAGE ARTIFACTS
# ------------------------------------------------------------
echo "--- Staging Grafana artifacts ---" | tee -a "${LOG_FILE}"

cp -r "${SRC_DIR}/public" "${STAGED_DIR}/public"
cp -r "${SRC_DIR}/conf" "${STAGED_DIR}/conf"

[[ -d "${SRC_DIR}/provisioning" ]] \
  && cp -r "${SRC_DIR}/provisioning" "${STAGED_DIR}/provisioning"
[[ -d "${SRC_DIR}/plugins" ]] \
  && cp -r "${SRC_DIR}/plugins" "${STAGED_DIR}/plugins"

find "${SRC_DIR}/bin" -type f -name 'grafana*' -exec cp {} "${STAGED_DIR}/" \;

# ------------------------------------------------------------
# CLEAN-STAGE
# ------------------------------------------------------------
echo "--- Running clean-stage.sh ---" | tee -a "${LOG_FILE}"
/opt/ansible/staged/grafana/scripts/clean-stage.sh "${GRAFANA_VERSION}"

# ------------------------------------------------------------
# WRITE VERSION INVENTORY
# ------------------------------------------------------------
cat << EOF > "${VERSION_INVENTORY}"
STAGED_GRAFANA_VERSION=${GRAFANA_VERSION}
STAGED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Also write global inventory for build sync
cat << EOF > "${GLOBAL_INVENTORY}"
LATEST_STAGED_GRAFANA_VERSION=${GRAFANA_VERSION}
STAGED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# ------------------------------------------------------------
# SYNC INTO BUILD STRUCTURE
# ------------------------------------------------------------
echo "--- Syncing staged Grafana ${GRAFANA_VERSION} into build structure ---" | tee -a "${LOG_FILE}"
"${BUILD_SYNC}" "${GRAFANA_VERSION}" | tee -a "${LOG_FILE}"

echo "=== Grafana ${GRAFANA_VERSION} staging + sync complete ===" | tee -a "${LOG_FILE}"
