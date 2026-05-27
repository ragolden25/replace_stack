#!/bin/bash
# guac-build-diagnostics.sh
set -e

echo "=== Checking pkg-config for libpng ==="
if pkg-config --libs libpng 2>/dev/null; then
    echo "OK: pkg-config sees libpng"
else
    echo "FAIL: pkg-config cannot find libpng"
fi

echo
echo "=== Checking ldconfig for libpng ==="
if ldconfig -p | grep -i png; then
    echo "OK: ldconfig sees libpng"
else
    echo "FAIL: ldconfig cannot find libpng"
fi

echo
echo "=== Checking for png.h header ==="
if [ -f /usr/include/png.h ]; then
    echo "OK: png.h exists"
else
    echo "FAIL: png.h missing"
fi

echo
echo "=== Checking for zlib.h header ==="
if [ -f /usr/include/zlib.h ]; then
    echo "OK: zlib.h exists"
else
    echo "FAIL: zlib.h missing"
fi

echo
echo "=== Checking compiler ==="
if command -v gcc >/dev/null; then
    echo "OK: gcc exists"
else
    echo "FAIL: gcc missing"
fi

echo
echo "=== Checking if tarball is real source ==="
if file guacamole-server-1.6.0.tar.gz | grep -qi gzip; then
    echo "OK: tarball is a real gzip archive"
else
    echo "FAIL: tarball is NOT a gzip archive (likely HTML!)"
fi

echo
echo "=== Checking configure script ==="
if [ -f ./configure ]; then
    if head -n 1 ./configure | grep -qi "shell script"; then
        echo "OK: configure script looks valid"
    else
        echo "FAIL: configure script is NOT valid"
    fi
else
    echo "FAIL: configure script missing"
fi

echo
echo "=== Checking for Makefile.in ==="
if [ -f Makefile.in ]; then
    echo "OK: Makefile.in exists"
else
    echo "FAIL: Makefile.in missing"
fi

echo
echo "=== Checking for autoconf tools ==="
if command -v autoreconf >/dev/null; then
    echo "OK: autoreconf exists"
else
    echo "FAIL: autoreconf missing"
fi
echo
echo "=== DONE ==="
