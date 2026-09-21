#!/usr/bin/env bash
set -euo pipefail
export PATH="/usr/local/bin:$PATH"

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
# COMPLETENESS CHECK
# ------------------------------------------------------------
is_complete() {
    [[ -d "${STAGED_DIR}/public" ]] || return 1
    [[ -d "${STAGED_DIR}/conf" ]] || return 1
    [[ -f "${STAGED_DIR}/grafana-server" ]] || return 1
    [[ -f "${STAGED_DIR}/grafana-cli" ]] || return 1
    return 0
}

# ------------------------------------------------------------
# VERSION GATE
# ------------------------------------------------------------
# FIX: was checking ${INVENTORY_FILE}, never defined anywhere in this
# script (the variable is VERSION_INVENTORY) — under `set -u` that's
# an immediate "unbound variable" crash before the clone even starts.
if [[ -f "${VERSION_INVENTORY}" ]]; then
    echo "--- Found existing inventory.env ---" | tee -a "${LOG_FILE}"
    source "${VERSION_INVENTORY}"

    if [[ "${STAGED_GRAFANA_VERSION:-}" == "${GRAFANA_VERSION}" ]]; then
        echo "--- Version matches; checking completeness ---" | tee -a "${LOG_FILE}"

        if is_complete; then
            echo "--- Staging complete; skipping rebuild ---" | tee -a "${LOG_FILE}"
            exit 0
        else
            echo "--- Staging incomplete; clearing old staging ---" | tee -a "${LOG_FILE}"
            rm -rf "${SRC_DIR:?}" "${STAGED_DIR:?}"
        fi
    else
        echo "--- Version mismatch; clearing old staging ---" | tee -a "${LOG_FILE}"
        rm -rf "${SRC_DIR:?}" "${STAGED_DIR:?}"
    fi
else
    echo "--- No inventory.env found; staging required ---" | tee -a "${LOG_FILE}"
    rm -rf "${SRC_DIR:?}" "${STAGED_DIR:?}"
fi

# FIX: "dir"/* doesn't match dotfiles (.git, .yarn), so a leftover
# .git/ from an interrupted prior clone survives a glob-based cleanup
# and makes `git clone` below fail ("already exists and is not an
# empty directory"). Removing+recreating the directories (above and
# here) avoids that regardless of what's left behind.
mkdir -p "${SRC_DIR}" "${STAGED_DIR}"

# ------------------------------------------------------------
# SHALLOW CLONE
# ------------------------------------------------------------
echo "--- Cloning Grafana v${GRAFANA_VERSION} (shallow) ---" | tee -a "${LOG_FILE}"

git clone --depth 1 --branch "v${GRAFANA_VERSION}" \
    "${REPO_URL}" "${SRC_DIR}" \
    2>&1 | tee -a "${LOG_FILE}"

echo "--- Clone complete ---" | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# RELOCATE GO BUILD CACHE
# ------------------------------------------------------------
export GOCACHE="/opt/ansible/go-cache"
export GOMODCACHE="/opt/ansible/go-mod"
export TMPDIR="/opt/ansible/tmp"

mkdir -p "$GOCACHE" "$GOMODCACHE" "$TMPDIR"

echo "--- Go build cache relocated ---" | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# APPLY YARN/NX OVERRIDES
# ------------------------------------------------------------
echo "--- Applying Yarn/Nx overrides ---" | tee -a "${LOG_FILE}"

jq '.resolutions += { "node-gyp": "^10.0.0" }' "${SRC_DIR}/package.json" > "${SRC_DIR}/package.new.json"
mv "${SRC_DIR}/package.new.json" "${SRC_DIR}/package.json"

# ------------------------------------------------------------
# INSTALL UI DEPENDENCIES
# ------------------------------------------------------------
# container-forge/debian13-node22 has no yarn/yarnpkg installed at all
# (Debian's yarnpkg package depends on nodejs (<21), incompatible with
# Node 22 no matter the install order) — and Corepack, the other
# candidate, ignores this project's vendored yarnPath and tries to
# fetch its pinned version from the network instead. Grafana ships the
# exact Yarn release it needs directly in its own repo
# (.yarn/releases/yarn-4.11.0.cjs, per .yarnrc.yml's yarnPath), so we
# run that file with `node` directly — same result as `yarn install`,
# no system yarn required, no network fetch needed.
echo "--- Installing Grafana UI dependencies ---" | tee -a "${LOG_FILE}"
timeout --signal=KILL 30m docker run --rm --network host \
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
timeout --signal=KILL 30m docker run --rm --network host \
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
# FIX: GOFLAGS space-splits on whitespace, so an unescaped
# "-ldflags=-s -w" parses as two flags — "-ldflags=-s" (fine) and a
# bare "-w" (not a valid top-level go build flag), which would fail
# this step outright. Escaping the internal space keeps "-s -w"
# together as one -ldflags value.
timeout --signal=KILL 20m docker run --rm --network host \
  -v "${SRC_DIR}:/workspace" \
  -v /opt/ansible/go-cache:/opt/go-cache \
  -v /opt/ansible/go-mod:/opt/go-mod \
  -v /opt/ansible/tmp:/opt/tmp \
  -w /workspace \
  -e GOCACHE=/opt/go-cache \
  -e GOMODCACHE=/opt/go-mod \
  -e TMPDIR=/opt/tmp \
  -e CGO_ENABLED=0 \
  -e GOFLAGS="-ldflags=-s\ -w" \
  -e GRAFANA_TAGS=oss \
  container-forge/debian13-go:latest \
  bash -c "make build-go" 2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# CLEAN-STAGE
# ------------------------------------------------------------
echo "--- Running clean-stage.sh ---" | tee -a "${LOG_FILE}"
/opt/ansible/staged/grafana/scripts/clean-stage.sh "${GRAFANA_VERSION}"

# ------------------------------------------------------------
# STAGE ARTIFACTS
# ------------------------------------------------------------
echo "--- Staging Grafana artifacts ---" | tee -a "${LOG_FILE}"

cp -r "${SRC_DIR}/public" "${STAGED_DIR}/public"
cp -r "${SRC_DIR}/conf" "${STAGED_DIR}/conf"

[[ -d "${SRC_DIR}/provisioning" ]] && cp -r "${SRC_DIR}/provisioning" "${STAGED_DIR}/provisioning"
[[ -d "${SRC_DIR}/plugins" ]] && cp -r "${SRC_DIR}/plugins" "${STAGED_DIR}/plugins"

find "${SRC_DIR}/bin" -type f -name 'grafana*' -exec cp {} "${STAGED_DIR}/" \;

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
