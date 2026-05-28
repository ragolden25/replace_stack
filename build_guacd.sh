#!/bin/bash
set -euo pipefail

VERSION="$1"
QUARTER="$2"

BUILD_ROOT="/opt/ansible/files/build/guacd/${QUARTER}"

cd "${BUILD_ROOT}"

# Optional: ensure required files are present (debian13_fips, src, Dockerfile.guacd, etc.)
# [you already have these staged in this directory]

echo "Building guacd ${VERSION} for ${QUARTER} in ${BUILD_ROOT}..."

docker build \
  -t "nucleus/guacd:${VERSION}" \
  -f Dockerfile.guacd \
  .

# Record the version for save_images.yml
echo "${VERSION}" > "${BUILD_ROOT}/VERSION"

echo "guacd ${VERSION} build complete."
