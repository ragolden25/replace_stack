stage_prometheus_source.sh
#!/usr/bin/env bash

set -euo pipefail
export PATH="/usr/local/bin:$PATH"

# ------------------------------------------------------------
# GLOBAL PNPM ENV (build-time only)
# ------------------------------------------------------------
export PNPM_ENABLE_OPTIONAL=true
export PNPM_IGNORE_SCRIPTS=false
export PNPM_ALLOW_BUILDS=true
export PNPM_APPROVE_BUILDS=true

echo "=== 1. Validating positional arguments ==="

# PROMETHEUS_VERSION is OPTIONAL → auto-detect latest stable
if [[ $# -ge 1 ]]; then
    PROMETHEUS_VERSION="$1"
else
    echo "--- No PROMETHEUS_VERSION provided; resolving latest stable tag ---"
    PROMETHEUS_VERSION="$(
      curl -s https://api.github.com/repos/prometheus/prometheus/releases \
        | grep -oP '"tag_name":\s*"v\K[0-9]+\.[0-9]+\.[0-9]+' \
        | grep -vE '(-rc|-beta|-alpha)' \
        | sort -V \
        | tail -n1
    )"

    if [[ -z "${PROMETHEUS_VERSION}" ]]; then
        echo "ERROR: Unable to determine latest Prometheus version" >&2
        exit 1
    fi

    echo "--- Using latest stable Prometheus version: ${PROMETHEUS_VERSION} ---"
fi

echo "=== 2. Structuring out-of-band file path variables ==="

BASE_DIR="/opt/ansible/staged/prometheus/${PROMETHEUS_VERSION}"
SRC_DIR="${BASE_DIR}/src"
STAGED_DIR="${BASE_DIR}/staged"
LOG_DIR="${BASE_DIR}/logs"
LOG_FILE="${LOG_DIR}/stage_prometheus_${PROMETHEUS_VERSION}.log"
INVENTORY_FILE="${STAGED_DIR}/inventory.env"

echo "=== 3. Ensuring core directory stanzas exist ==="
mkdir -p "${LOG_DIR}"

echo "=== 4. FAILED ATTEMPT CLEANUP CHECK ==="

# If inventory.env is missing → cleanup
if [[ ! -f "${INVENTORY_FILE}" ]]; then
    echo "--- No inventory.env found; cleaning failed attempt ---"
    rm -rf "${BASE_DIR}"
fi

# If src exists but is empty → cleanup
if [[ -d "${SRC_DIR}" && -z "$(ls -A "${SRC_DIR}")" ]]; then
    echo "--- Empty src directory detected; cleaning failed attempt ---"
    rm -rf "${BASE_DIR}"
fi

# If staged exists but is empty → cleanup
if [[ -d "${STAGED_DIR}" && -z "$(ls -A "${STAGED_DIR}")" ]]; then
    echo "--- Empty staged directory detected; cleaning failed attempt ---"
    rm -rf "${BASE_DIR}"
fi

# If staged exists but binaries are missing → cleanup
if [[ -d "${STAGED_DIR}" ]]; then
    if [[ ! -f "${STAGED_DIR}/prometheus" || ! -f "${STAGED_DIR}/promtool" ]]; then
        echo "--- Missing Prometheus binaries; cleaning failed attempt ---"
        rm -rf "${BASE_DIR}"
    fi
fi

# Recreate clean directory structure
mkdir -p "${SRC_DIR}" "${STAGED_DIR}" "${LOG_DIR}"

echo "=== 5. Initializing milestone logging anchors ==="
echo "=== Prometheus ${PROMETHEUS_VERSION} Staging ===" | tee "${LOG_FILE}"
echo "Source directory: ${SRC_DIR}" | tee -a "${LOG_FILE}"
echo "Staged directory: ${STAGED_DIR}" | tee -a "${LOG_FILE}"
echo "Log file: ${LOG_FILE}" | tee -a "${LOG_FILE}"

echo "=== 6. Version Gate: Evaluating current cached inventory state ==="
if [[ -f "${INVENTORY_FILE}" ]]; then
    echo "--- Found existing inventory.env ---" | tee -a "${LOG_FILE}"
    source "${INVENTORY_FILE}"

    if [[ "${STAGED_PROMETHEUS_VERSION:-}" == "${PROMETHEUS_VERSION}" ]]; then
        echo "--- Prometheus ${PROMETHEUS_VERSION} already staged; skipping ---" | tee -a "${LOG_FILE}"
        exit 0
    else
        echo "--- Version mismatch; clearing old staging ---" | tee -a "${LOG_FILE}"
        rm -rf "${SRC_DIR:?}"/* "${STAGED_DIR:?}"/*
    fi
else
    echo "--- No inventory.env found; staging required ---" | tee -a "${LOG_FILE}"
    rm -rf "${SRC_DIR:?}"/* "${STAGED_DIR:?}"/*
fi

mkdir -p "${SRC_DIR}" "${STAGED_DIR}"

echo "=== 7. Cloning pure stable Prometheus version source tree ==="
git clone --depth 1 --branch "v${PROMETHEUS_VERSION}" https://github.com/prometheus/prometheus.git "${SRC_DIR}" \
    2>&1 | tee -a "${LOG_FILE}"

# ------------------------------------------------------------
# NEW: Inject pnpm reproducible-build approval templates
# ------------------------------------------------------------
inject_pnpm_approvals() {
    local dest_root="$1"
    local template_root="/opt/ansible/staged/prometheus/pnpm_approval_templates"

    echo "=== Injecting pnpm reproducible-build approval templates ==="

    for ws in \
        "web/ui" \
        "web/ui/react-app"
    do
        local dest_path="${dest_root}/${ws}/node_modules/.pnpm"
        local src_path="${template_root}/${ws}"

        if [[ ! -d "$dest_path" ]]; then
            echo "SKIP: $dest_path not found"
            continue
        fi

        echo "--- Injecting into: $dest_path ---"

        cp "${src_path}/lock.yaml" "${dest_path}/lock.yaml"
        cp "${src_path}/allowed-builds" "${dest_path}/allowed-builds"
        cp "${src_path}/ignored-builds" "${dest_path}/ignored-builds"

        echo "✓ Injected approval manifest for $ws"
    done

    echo "=== pnpm approval template injection complete ==="
}

inject_pnpm_approvals "${SRC_DIR}"

echo "=== 8. Applying local network pnpm package tracking overrides ==="

apply_overrides() {
    local ws="$1"

    grep -q '^overrides:' "$ws" || echo 'overrides:' >> "$ws"

    sed -i '/^overrides:/a\  http-proxy-middleware: "3.0.7"' "$ws"
    sed -i '/^overrides:/a\  immutable: "5.1.8"' "$ws"
    sed -i '/^overrides:/a\  postcss: "8.5.18"' "$ws"
}

docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui/react-app \
  container-forge/debian13-node22:latest \
  bash -c "pnpm --version" \
  2>&1 | tee -a "${LOG_FILE}"

apply_overrides "${SRC_DIR}/web/ui/react-app/pnpm-workspace.yaml"

echo "=== 9. Cleaning invalid approval keys ==="

apply_approvals() {
    local ws="$1"
    sed -i '/approve-builds:/d' "$ws"
}

for ws in \
    "${SRC_DIR}/web/ui/pnpm-workspace.yaml" \
    "${SRC_DIR}/web/ui/react-app/pnpm-workspace.yaml" \
    "${SRC_DIR}/module/codemirror-promql/pnpm-workspace.yaml"
do
    if [[ -f "$ws" ]]; then
        apply_approvals "$ws"
    fi
done

echo "=== 10. Forcing dependency configuration rule patches ==="

apply_dep_rules() {
    local ws="$1"

    grep -q '^strictDepBuilds:' "$ws" || echo 'strictDepBuilds: true' >> "$ws"
    grep -q '^allowBuilds:' "$ws" || echo 'allowBuilds:' >> "$ws"
}

for ws in \
    "${SRC_DIR}/web/ui/pnpm-workspace.yaml" \
    "${SRC_DIR}/web/ui/react-app/pnpm-workspace.yaml" \
    "${SRC_DIR}/module/codemirror-promql/pnpm-workspace.yaml"
do
    if [[ -f "$ws" ]]; then
        apply_dep_rules "$ws"
    fi
done

echo "=== 11. Pre-seeding pnpm approval files in workspace ==="

for ws in \
    "${SRC_DIR}/web/ui" \
    "${SRC_DIR}/web/ui/react-app" \
    "${SRC_DIR}/module/codemirror-promql"
do
    mkdir -p "$ws/node_modules/.pnpm"
    touch "$ws/node_modules/.pnpm/allowed-builds"
    touch "$ws/node_modules/.pnpm/ignored-builds"
done

echo "=== 12. Compiling local web asset requirements ==="

docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui/react-app \
  container-forge/debian13-node22:latest \
  pnpm install 2>&1 | tee -a "${LOG_FILE}"

echo "=== Approving pnpm build scripts (react-app) ==="
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui/react-app \
  container-forge/debian13-node22:latest \
  pnpm approve-builds --force 2>&1 | tee -a "${LOG_FILE}" || true

docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui \
  container-forge/debian13-node22:latest \
  pnpm install 2>&1 | tee -a "${LOG_FILE}"

echo "=== Approving pnpm build scripts (web/ui) ==="
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui \
  container-forge/debian13-node22:latest \
  pnpm approve-builds --force 2>&1 | tee -a "${LOG_FILE}" || true

echo "=== 13. Executing static code package diagnostic hooks ==="
docker run --rm \
  -v "${SRC_DIR}:/workspace" \
  -w /workspace/web/ui/react-app \
  container-forge/debian13-node22:latest \
  pnpm peers check 2>&1 | tee -a "${LOG_FILE}" || \
  echo "--- pnpm peers check reported issues (logged only) ---" | tee -a "${LOG_FILE}"

echo "=== 14. Compressing compiled system UI bundles ==="
(
    cd "${SRC_DIR}"
    make assets assets-compress 2>&1 | tee -a "${LOG_FILE}"
)

echo "=== 15. Executing compilation rules for main Go binaries ==="
(
    cd "${SRC_DIR}"

    BUILD_DATE=$(date -u "+%Y%m%d-%H:%M:%S")
    GIT_REV=$(git rev-parse HEAD)

    GOLDFLAGS="-X github.com/prometheus/common/version.Version=${PROMETHEUS_VERSION} \
-X github.com/prometheus/common/version.Revision=${GIT_REV} \
-X github.com/prometheus/common/version.Branch=HEAD \
-X github.com/prometheus/common/version.BuildUser=builder@ansible-forge \
-X github.com/prometheus/common/version.BuildDate=${BUILD_DATE} \
-X github.com/prometheus/prometheus/version.Version=${PROMETHEUS_VERSION}"

    docker run --rm \
      -v "${SRC_DIR}:/workspace" \
      -w /workspace \
      -e CGO_ENABLED=0 \
      container-forge/debian13-go:latest \
      bash -c "
        make plugins && \
        go build -buildvcs=false -mod=readonly -ldflags \"$GOLDFLAGS\" -tags netgo,builtinassets,stringlabels -o prometheus ./cmd/prometheus && \
        go build -buildvcs=false -mod=readonly -ldflags \"$GOLDFLAGS\" -o promtool ./cmd/promtool
      " 2>&1 | tee -a "${LOG_FILE}"
)

echo "=== 16. Deploying completed assets to local staging targets ==="
cp "${SRC_DIR}/prometheus" "${STAGED_DIR}/prometheus"
cp "${SRC_DIR}/promtool" "${STAGED_DIR}/promtool"
cp "${SRC_DIR}/documentation/examples/prometheus.yml" "${STAGED_DIR}/prometheus.yml"

if [[ -d "${SRC_DIR}/consoles" ]]; then
    cp -r "${SRC_DIR}/consoles" "${STAGED_DIR}/consoles"
fi

if [[ -d "${SRC_DIR}/console_libraries" ]]; then
    cp -r "${SRC_DIR}/console_libraries" "${STAGED_DIR}/console_libraries"
fi

echo "=== 17. Writing dynamic pipeline deployment variables ==="

CLEAN_VERSION="${PROMETHEUS_VERSION//\"/}"

cat << EOF > "${INVENTORY_FILE}"
STAGED_PROMETHEUS_VERSION="${CLEAN_VERSION}"
STAGED_TIMESTAMP="$(date -Iseconds)"
EOF


echo "=== 18. Clearing internal compiler cache frameworks ==="
(
    docker run --rm \
      -v "${SRC_DIR}:/workspace" \
      -w /workspace \
      container-forge/debian13-go:latest \
      go clean -cache 2>/dev/null || true

    rm -rf "${SRC_DIR}/.cache" || true
)

/opt/ansible/build/grafana_stack/prometheus/scripts/sync-latest-version.sh "${CLEAN_VERSION}"
echo "=== Staging Complete! Prometheus ${PROMETHEUS_VERSION} stands ready for stack deployment ===" | tee -a "${LOG_FILE}"
