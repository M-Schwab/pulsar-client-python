#!/usr/bin/env bash
#
# Build the rf-pulsar-client manylinux wheels into ./wheelhouse.
#
# Mirrors pkg/build-wheel-inside-docker.sh, but builds the C++ client once and
# then one wheel per Python version, all in a single manylinux container.
#
# usage: rf/build-manylinux-wheels.sh [x86_64|aarch64] [python specs...]
#   e.g. rf/build-manylinux-wheels.sh x86_64 cp312-cp312 cp313-cp313 cp314-cp314

set -euo pipefail

ARCH=${1:-x86_64}
shift || true
SPECS=${*:-cp312-cp312 cp313-cp313 cp314-cp314}
ROOT=$(cd "$(dirname "$0")/.." && pwd)

mkdir -p "$ROOT/wheelhouse"
docker run --rm -i \
    -v "$ROOT:/src:ro" \
    -v "$ROOT/wheelhouse:/out" \
    -e SPECS="$SPECS" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "quay.io/pypa/manylinux_2_28_${ARCH}" \
    bash -euxo pipefail <<'EOF'
yum install -y -q curl zip unzip tar perl-IPC-Cmd perl-Time-Piece

# A writable copy without local build output.
cp -r /src /build
cd /build
rm -rf build wheelhouse dist ./*.so

source build-support/dep-url.sh
CPP_VERSION=$(grep pulsar-cpp dependencies.yaml | awk '{print $2}')

# The C++ client, built from source: the pre-built RPMs' ABI is incompatible
# with manylinux (see pkg/build-wheel-inside-docker.sh).
download_dependency ./dependencies.yaml pulsar-cpp
cd apache-pulsar-client-cpp-${CPP_VERSION}
git clone -q https://github.com/microsoft/vcpkg.git
git clone -q -b release https://github.com/ninja-build/ninja.git vcpkg/ninja
(cd vcpkg/ninja && ./configure.py --bootstrap && mv ninja /usr/bin/)
./vcpkg/bootstrap-vcpkg.sh
cmake -B build-cpp -DINTEGRATE_VCPKG=ON -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTS=OFF \
    -DBUILD_DYNAMIC_LIB=ON -DBUILD_STATIC_LIB=ON
cmake --build build-cpp -j"$(nproc)" --target install
cd /build

for spec in $SPECS; do
    py=/opt/python/$spec/bin/python
    $py -m pip install -q setuptools wheel
    rm -rf build lib_pulsar.so dist
    cmake -B build -DCMAKE_BUILD_TYPE=Release -DPython3_ROOT_DIR=/opt/python/$spec \
        -DPython3_FIND_STRATEGY=LOCATION
    cmake --build build -j"$(nproc)"
    mv build/lib_pulsar.so .
    $py setup.py -q bdist_wheel
    auditwheel repair -w /out dist/rf_pulsar_client-*-$spec-linux_*.whl
done
chown -R "$HOST_UID:$HOST_GID" /out
EOF
ls -l "$ROOT/wheelhouse"
