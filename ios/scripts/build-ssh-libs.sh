#!/bin/bash
# Tera Term SP (iPhone / iPad) のための SSH ライブラリ (libssh2 + OpenSSL の libcrypto) を公式のソースから組み立てる。
# iPhone には ssh コマンドがないので、アプリの中の SSH (libssh2) でつなぐ。
#
#   ./scripts/build-ssh-libs.sh [sim|device]   (既定 sim: この Mac のシミュレーター)
#
# できるもの: Vendor/ssh-<sim|device>/{include,lib/libssh2.a,lib/libcrypto.a}
# ライセンス: OpenSSL 3 は Apache License 2.0、libssh2 は BSD 3-Clause
set -euo pipefail

OPENSSL_VER=3.5.9
LIBSSH2_VER=1.11.1
MIN_IOS=15.0
KIND="${1:-sim}"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${TMPDIR:-/tmp}/terasp-ssh-libs"
OUT="$HERE/Vendor/ssh-$KIND"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK/src" "$OUT/lib" "$OUT/include"

fetch() { [ -f "$WORK/src/$2" ] || curl -fL --retry 3 -o "$WORK/src/$2" "$1"; }
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz" "openssl-$OPENSSL_VER.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VER/openssl-$OPENSSL_VER.tar.gz.sha256" "openssl-$OPENSSL_VER.tar.gz.sha256"
fetch "https://github.com/libssh2/libssh2/releases/download/libssh2-$LIBSSH2_VER/libssh2-$LIBSSH2_VER.tar.gz" "libssh2-$LIBSSH2_VER.tar.gz"
want="$(awk '{print $1}' "$WORK/src/openssl-$OPENSSL_VER.tar.gz.sha256")"
got="$(shasum -a 256 "$WORK/src/openssl-$OPENSSL_VER.tar.gz" | awk '{print $1}')"
[ "$want" = "$got" ] || { echo "openssl: sha256 が合いません ($got)"; exit 1; }
got="$(shasum -a 256 "$WORK/src/libssh2-$LIBSSH2_VER.tar.gz" | awk '{print $1}')"
[ "$got" = "d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7" ] || { echo "libssh2: sha256 が合いません ($got)"; exit 1; }

if [ "$KIND" = sim ]; then
    SDKNAME=iphonesimulator; ARCH="$(uname -m)"; OSSL_TARGET=iossimulator-xcrun
    VMIN="-mios-simulator-version-min=$MIN_IOS"
    HOST=$([ "$ARCH" = arm64 ] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
else
    SDKNAME=iphoneos; ARCH=arm64; OSSL_TARGET=ios64-xcrun; VMIN="-miphoneos-version-min=$MIN_IOS"; HOST=aarch64-apple-darwin
fi
SDK="$(xcrun --sdk $SDKNAME --show-sdk-path)"
P="$WORK/$KIND-$ARCH"
export CROSS_TOP= CROSS_SDK=
if [ ! -f "$P/lib/libcrypto.a" ]; then
    rm -rf "$WORK/b-openssl-$KIND"; mkdir -p "$WORK/b-openssl-$KIND"
    tar -xzf "$WORK/src/openssl-$OPENSSL_VER.tar.gz" -C "$WORK/b-openssl-$KIND" --strip-components 1
    (cd "$WORK/b-openssl-$KIND" &&
     CC="xcrun --sdk $SDKNAME clang -arch $ARCH" ./Configure "$OSSL_TARGET" no-shared no-tests no-apps no-docs no-engine no-dso no-module no-async \
        --prefix="$P" --libdir=lib $VMIN >/dev/null &&
     make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)
fi
if [ ! -f "$P/lib/libssh2.a" ]; then
    rm -rf "$WORK/b-libssh2-$KIND"; mkdir -p "$WORK/b-libssh2-$KIND"
    tar -xzf "$WORK/src/libssh2-$LIBSSH2_VER.tar.gz" -C "$WORK/b-libssh2-$KIND" --strip-components 1
    (cd "$WORK/b-libssh2-$KIND" &&
     CC="xcrun --sdk $SDKNAME clang" CFLAGS="-arch $ARCH $VMIN -isysroot $SDK -O2" \
     ./configure --host=$HOST --prefix="$P" --disable-shared --enable-static --with-crypto=openssl \
        --with-libssl-prefix="$P" --disable-examples-build --disable-docker-tests --without-libz >/dev/null &&
     make -j"$JOBS" >/dev/null && make install >/dev/null)
fi
cp "$P/lib/libcrypto.a" "$P/lib/libssh2.a" "$OUT/lib/"
cp "$P/include/libssh2.h" "$P/include/libssh2_publickey.h" "$P/include/libssh2_sftp.h" "$OUT/include/"
cp "$P/include/libssh2"*.h "$HERE/Sources/CSSH2/include/"   # CSSH2.h から読む (同じフォルダ)
printf 'OpenSSL %s (Apache License 2.0)\nlibssh2 %s (BSD 3-Clause)\niOS %s %s %s\n' $OPENSSL_VER $LIBSSH2_VER $MIN_IOS $KIND $ARCH > "$OUT/VERSIONS"
lipo -info "$OUT/lib/"*.a
echo "done: $OUT"
