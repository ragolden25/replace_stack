mmdebstrap-build-node22.sh
#!/bin/bash

NODE22_OUTPUT_DIR="/var/www/html/images/debian13-node22"
TAG="$(date +%Y%m%d)"

echo "=== 22. Build debian13-node22 image ==="
docker build \
        --add-host=trixie.nuc2.scires.com:192.168.110.213 \
        --no-cache -f "$NODE22_OUTPUT_DIR/Dockerfile.debian13.node22" -t container-forge/debian13-node22:latest "$NODE22_OUTPUT_DIR"
docker tag container-forge/debian13-node22:latest container-forge/debian13-node22:"$TAG"

echo "=== 23. Export debian13-node22 archives ==="
docker save container-forge/debian13-node22:"$TAG" | gzip > "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz"
docker save container-forge/debian13-node22:latest | gzip > "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz"

echo "=== 24. Digest & GPG signatures for debian13-node22 ==="
sha256sum "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz" | awk '{print $1}' > "$NODE22_OUTPUT_DIR/digest-$TAG.txt"
sha256sum "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz" | awk '{print $1}' > "$NODE22_OUTPUT_DIR/digest-latest.txt"

gpg --batch --yes --pinentry-mode loopback --detach-sign --output "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.digest.asc" "$NODE22_OUTPUT_DIR/digest-$TAG.txt"
gpg --batch --yes --pinentry-mode loopback --detach-sign --output "$NODE22_OUTPUT_DIR/debian13-node22-latest.digest.asc" "$NODE22_OUTPUT_DIR/digest-latest.txt"
gpg --batch --yes --pinentry-mode loopback --detach-sign --output "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz.asc" "$NODE22_OUTPUT_DIR/debian13-node22-$TAG.tar.gz"
gpg --batch --yes --pinentry-mode loopback --detach-sign --output "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz.asc" "$NODE22_OUTPUT_DIR/debian13-node22-latest.tar.gz"
