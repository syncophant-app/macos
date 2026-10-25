#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v cmake >/dev/null || { echo 'Install CMake before building.' >&2; exit 1; }
command -v pkg-config >/dev/null || { echo 'Install pkg-config before building.' >&2; exit 1; }
mkdir -p .deps/src .deps/lib .deps/notices
openssl_prefix="$PWD/.deps"
openssl_archive=.deps/src/openssl-3.5.9.tar.gz
if [[ ! -f .deps/.openssl-3.5.9-macos26 ]]; then
  if [[ ! -f "$openssl_archive" ]]; then
    curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 180 \
      https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz --output "$openssl_archive"
  fi
  echo '603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a  .deps/src/openssl-3.5.9.tar.gz' | shasum -a 256 -c -
  tar xzf "$openssl_archive" -C .deps/src
  case "$(uname -m)" in
    arm64) openssl_target=darwin64-arm64-cc ;;
    x86_64) openssl_target=darwin64-x86_64-cc ;;
    *) echo 'Unsupported Mac architecture.' >&2; exit 1 ;;
  esac
  (
    cd .deps/src/openssl-3.5.9
    ./Configure "$openssl_target" no-shared no-tests no-module --prefix="$openssl_prefix" --libdir=lib -mmacosx-version-min=26.0
    make -j8 build_libs
    make install_dev
  )
  cp .deps/src/openssl-3.5.9/LICENSE.txt .deps/notices/OpenSSL.txt
  touch .deps/.openssl-3.5.9-macos26
fi
archive=.deps/src/libssh2-1.11.1.tar.gz
if [[ ! -f "$archive" ]]; then
  curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 120 \
    https://libssh2.org/download/libssh2-1.11.1.tar.gz --output "$archive"
fi
echo 'd9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7  .deps/src/libssh2-1.11.1.tar.gz' | shasum -a 256 -c -
if [[ ! -f .deps/.libssh2-1.11.1-openssl359 ]]; then
  tar xzf "$archive" -C .deps/src
  cmake -S .deps/src/libssh2-1.11.1 -B .deps/ssh-build \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0 \
    -DCMAKE_INSTALL_PREFIX="$PWD/.deps" -DBUILD_SHARED_LIBS=OFF -DBUILD_STATIC_LIBS=ON \
    -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DCRYPTO_BACKEND=OpenSSL \
    -DOPENSSL_ROOT_DIR="$openssl_prefix" -DOPENSSL_USE_STATIC_LIBS=TRUE \
    -DOPENSSL_INCLUDE_DIR="$openssl_prefix/include" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_prefix/lib/libcrypto.a" \
    -DOPENSSL_SSL_LIBRARY="$openssl_prefix/lib/libssl.a"
  cmake --build .deps/ssh-build --parallel 8
  cmake --install .deps/ssh-build
  touch .deps/.libssh2-1.11.1-openssl359
fi
cp .deps/src/libssh2-1.11.1/COPYING .deps/notices/libssh2.txt
echo 'Static libssh2 1.11.1 and OpenSSL 3.5.9 (macOS 26) ready in .deps.'
