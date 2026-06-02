#!/usr/bin/env bash
set -euo pipefail

QUARTER="fy26q3"
BASE_DIR="/opt/ansible/files/build/guacd/${QUARTER}"
SRC_DIR="${BASE_DIR}/sources"

mkdir -p "${SRC_DIR}"
cd "${SRC_DIR}"

download() {
    local url="$1"
    local out="$2"

    if [[ -f "${out}" ]]; then
        echo "[SKIP] ${out} already exists"
        return
    fi

    echo "[GET ] ${out} from ${url}"
    curl -fSL "${url}" -o "${out}.tmp"
    # sanity check: don’t keep tiny HTML error pages
    local size
    size=$(stat -c '%s' "${out}.tmp")
    if [[ "${size}" -lt 50000 ]]; then
        echo "[FAIL] ${out} is suspiciously small (${size} bytes) – likely an error page"
        rm -f "${out}.tmp"
        exit 1
    fi
    mv "${out}.tmp" "${out}"
    echo "[OK  ] ${out} (${size} bytes)"
}

# FreeRDP 3.6.0
download \
  "https://github.com/FreeRDP/FreeRDP/archive/refs/tags/3.6.0.tar.gz" \
  "freerdp-3.6.0.tar.gz"

# libssh2 1.11.0
download \
  "https://www.libssh2.org/download/libssh2-1.11.0.tar.gz" \
  "libssh2-1.11.0.tar.gz"

# libtelnet 1.2
download \
  "https://github.com/seanmiddleditch/libtelnet/releases/download/1.2/libtelnet-1.2.tar.gz" \
  "libtelnet-1.2.tar.gz"

# libvncserver 0.9.14
download \
  "https://github.com/LibVNC/libvncserver/archive/refs/tags/LibVNCServer-0.9.14.tar.gz" \
  "libvncserver-0.9.14.tar.gz"

# libwebsockets 4.3.2
download \
  "https://github.com/warmcat/libwebsockets/archive/refs/tags/v4.3.2.tar.gz" \
  "libwebsockets-4.3.2.tar.gz"

# guacamole-server 1.6.0 – only download if you *don’t* already have it
if [[ ! -f "${SRC_DIR}/guacamole-server-1.6.0.tar.gz" ]]; then
    download \
      "https://apache.org/dyn/closer.lua/guacamole/1.6.0/source/guacamole-server-1.6.0.tar.gz" \
      "guacamole-server-1.6.0.tar.gz"
else
    echo "[SKIP] guacamole-server-1.6.0.tar.gz already present"
fi

echo "[DONE] All source tarballs present in ${SRC_DIR}"
