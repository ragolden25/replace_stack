#!/usr/bin/env bash
set -euo pipefail

LOG="guacd_build_$(date +%Y%m%d_%H%M%S).log"

echo "=== Guacd Build Confirmation & Auto Fix Script ==="
echo "Log: $LOG"
echo

log() {
    echo "[+] $1" | tee -a "$LOG"
}

fail() {
    echo "[ERROR] $1" | tee -a "$LOG"
    exit 1
}

# -----------------------------
# 1. Validate working directory
# -----------------------------
if [[ ! -d "./" ]]; then
    fail "Run this script inside the guacd build directory."
fi

# -----------------------------
# 2. Detect tarball
# -----------------------------
TARBALL=$(ls guacamole-server-*.tar.gz 2>/dev/null || true)

if [[ -z "$TARBALL" ]]; then
    fail "No guacamole-server-*.tar.gz tarball found."
fi

log "Found tarball: $TARBALL"

# -----------------------------
# 3. Ensure src/ exists
# -----------------------------
if [[ ! -d "src" ]]; then
    log "src/ directory missing — creating it."
    mkdir -p src
fi

# -----------------------------
# 4. Detect versioned directory
# -----------------------------
VERSIONED_DIR=$(find . -maxdepth 1 -type d -name "guacamole-server-*" | head -n 1 || true)

if [[ -n "$VERSIONED_DIR" ]]; then
    log "Detected versioned directory: $VERSIONED_DIR"
fi

# -----------------------------
# 5. Validate configure script
# -----------------------------
if [[ ! -f "src/configure" ]]; then
    log "src/configure missing — attempting auto fix."

    # If versioned directory exists, move it
    if [[ -n "$VERSIONED_DIR" ]]; then
        log "Moving $VERSIONED_DIR → src/"
        rm -rf src
        mv "$VERSIONED_DIR" src
    else
        log "No extracted directory found — re extracting tarball."
        rm -rf src
        mkdir src
        tar -xf "$TARBALL"
        VERSIONED_DIR=$(find . -maxdepth 1 -type d -name "guacamole-server-*" | head -n 1)
        mv "$VERSIONED_DIR" src
    fi
fi

# -----------------------------
# 6. Final check for configure
# -----------------------------
if [[ ! -f "src/configure" ]]; then
    fail "configure still missing after auto fix. Extraction path is broken."
fi

log "configure found."

# -----------------------------
# 7. Run configure
# -----------------------------
log "Running ./configure --prefix=/usr"
(
    cd src
    ./configure --prefix=/usr 2>&1 | tee -a "../$LOG"
)

# -----------------------------
# 8. Run make
# -----------------------------
log "Running make -j$(nproc)"
(
    cd src
    make -j"$(nproc)" 2>&1 | tee -a "../$LOG"
)

# -----------------------------
# 9. Run make install
# -----------------------------
log "Running make install"
(
    cd src
    make install 2>&1 | tee -a "../$LOG"
)

# -----------------------------
# 10. Validate install
# -----------------------------
if [[ ! -f "/usr/sbin/guacd" ]]; then
    fail "guacd binary missing after install."
fi

log "guacd installed successfully at /usr/sbin/guacd"
log "Build completed successfully."
echo
echo "=== DONE ==="
echo "Guacd build validated and repaired."
