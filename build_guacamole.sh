#!/bin/bash
set -euo pipefail

VERSION="$1"
QUARTER="$2"

BUILD_ROOT="/opt/ansible/files/build/guacamole/${QUARTER}"

cd "${BUILD_ROOT}"

# Optional: ensure required files are present (WAR, src, Dockerfile.guacamole, etc.)
# [you already have these staged in this directory]

echo "Building guacamole ${VERSION} for ${QUARTER} in ${BUILD_ROOT}..."

docker build \
  -t "nucleus/guacamole:${VERSION}" \
  -f Dockerfile.guacamole \
  .

# Record the version for save_images.yml
echo "${VERSION}" > "${BUILD_ROOT}/VERSION"

echo "guacamole ${VERSION} build complete."
