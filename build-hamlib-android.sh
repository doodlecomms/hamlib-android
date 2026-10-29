#!/usr/bin/env bash
# Builds Hamlib as a shared library (libhamlib.so) for Android with the
# android-usb: serial bridge patches in ./patches, and copies it into the
# app's jniLibs so Gradle packages it.
#
# Usage:  ANDROID_NDK_HOME=/path/to/ndk ./build-hamlib-android.sh
# Optional env: ABIS ("arm64-v8a armeabi-v7a x86_64"), ANDROID_API (26),
#               HAMLIB_REV, HAMLIB_SRC, WORK_DIR, JNILIBS_DIR, JOBS.
#
# Outputs:
#   out/<abi>/include/hamlib/*.h   headers for the app's JNI wrapper
#   out/<abi>/lib/libhamlib.so      unstripped (keep for symbolizing crashes)
#   <JNILIBS_DIR>/<abi>/libhamlib.so  stripped copy that ships in the APK
#                                     (the app's jniLibs, or ./jniLibs on its own)
#
# This script and ./patches are published under the LGPL-2.1-or-later (see
# README.md) so anyone can rebuild and relink the Hamlib in the app.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PATCH_DIR="${SCRIPT_DIR}/patches"
WORK_DIR="${WORK_DIR:-${SCRIPT_DIR}/.work}"
HAMLIB_SRC="${HAMLIB_SRC:-${WORK_DIR}/hamlib-src}"
OUT_DIR="${SCRIPT_DIR}/out"
# Inside the app repo, install straight into the app's jniLibs; on its own
# (the public copy), into ./jniLibs.
if [[ -z "${JNILIBS_DIR:-}" ]]; then
  if [[ -d "${SCRIPT_DIR}/../android/app/src/main" ]]; then
    JNILIBS_DIR="${SCRIPT_DIR}/../android/app/src/main/jniLibs"
  else
    JNILIBS_DIR="${SCRIPT_DIR}/jniLibs"
  fi
fi

# Pinned: the last Hamlib master revision the bridge patches apply to.
HAMLIB_REV="${HAMLIB_REV:-1b2461aba99f0dde0531e1732c00e60aeee40657}"
ANDROID_API="${ANDROID_API:-26}"
ABIS="${ABIS:-arm64-v8a armeabi-v7a x86_64}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "${NDK_ROOT}" ]]; then
  echo "Set ANDROID_NDK_HOME (or ANDROID_NDK_ROOT) to your NDK directory." >&2
  exit 1
fi

case "$(uname -s)" in
  Darwin) HOST_TAG="darwin-x86_64" ;;  # also the tag on Apple silicon
  Linux)  HOST_TAG="linux-x86_64" ;;
  *) echo "Unsupported host OS: $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN="${NDK_ROOT}/toolchains/llvm/prebuilt/${HOST_TAG}"
[[ -d "${TOOLCHAIN}" ]] || { echo "NDK toolchain not found: ${TOOLCHAIN}" >&2; exit 1; }

# Homebrew installs GNU libtool as glibtoolize; Hamlib's bootstrap wants libtoolize.
if ! command -v libtoolize >/dev/null 2>&1 && command -v glibtoolize >/dev/null 2>&1; then
  export LIBTOOLIZE=glibtoolize
  mkdir -p "${WORK_DIR}/bin"
  ln -sf "$(command -v glibtoolize)" "${WORK_DIR}/bin/libtoolize"
  export PATH="${WORK_DIR}/bin:${PATH}"
fi

# --- source: clone, pin, patch (idempotent) ---------------------------------
mkdir -p "${WORK_DIR}"
if [[ ! -d "${HAMLIB_SRC}/.git" ]]; then
  git clone https://github.com/Hamlib/Hamlib.git "${HAMLIB_SRC}"
fi
pushd "${HAMLIB_SRC}" >/dev/null
if [[ "$(git rev-parse HEAD)" != "${HAMLIB_REV}" ]]; then
  git fetch origin
  git checkout --detach "${HAMLIB_REV}"
fi
for patch in "${PATCH_DIR}"/*.patch; do
  if git apply --check "${patch}" 2>/dev/null; then
    echo "Applying $(basename "${patch}")"
    git apply "${patch}"
  elif git apply --reverse --check "${patch}" 2>/dev/null; then
    echo "Already applied: $(basename "${patch}")"
  else
    echo "Patch does not apply to ${HAMLIB_REV}: ${patch}" >&2
    echo "Reset the tree with: git -C '${HAMLIB_SRC}' checkout -- . && git -C '${HAMLIB_SRC}' clean -fd" >&2
    exit 1
  fi
done
[[ -x configure ]] || ./bootstrap
popd >/dev/null

# --- per-ABI build -------------------------------------------------------------
build_abi() {
  local abi="$1" target
  case "${abi}" in
    arm64-v8a)   target="aarch64-linux-android" ;;
    armeabi-v7a) target="armv7a-linux-androideabi" ;;
    x86_64)      target="x86_64-linux-android" ;;
    *) echo "Unknown ABI: ${abi}" >&2; return 1 ;;
  esac

  local build_dir="${WORK_DIR}/build/${abi}"
  local prefix="${OUT_DIR}/${abi}"
  rm -rf "${build_dir}" "${prefix}"
  mkdir -p "${build_dir}" "${prefix}"

  echo "=== Building Hamlib for ${abi} (${target}${ANDROID_API}) ==="
  pushd "${build_dir}" >/dev/null
  CC="${TOOLCHAIN}/bin/${target}${ANDROID_API}-clang" \
  CXX="${TOOLCHAIN}/bin/${target}${ANDROID_API}-clang++" \
  AR="${TOOLCHAIN}/bin/llvm-ar" \
  RANLIB="${TOOLCHAIN}/bin/llvm-ranlib" \
  STRIP="${TOOLCHAIN}/bin/llvm-strip" \
  NM="${TOOLCHAIN}/bin/llvm-nm" \
  CFLAGS="-O2 -fPIC" \
  LDFLAGS="-Wl,-z,max-page-size=16384" \
  "${HAMLIB_SRC}/configure" \
    --host="${target}" \
    --prefix="${prefix}" \
    --enable-shared \
    --disable-static \
    --without-cxx-binding \
    --without-libusb \
    --disable-winradio \
    --without-indi \
    --without-readline \
    --without-xml-support \
    --disable-html-matrix

  # Android only packages files named lib*.so and loads them by SONAME, so
  # drop libtool's version suffix (libhamlib.so.4 -> libhamlib.so).
  local ldflags="-no-undefined -avoid-version"
  make -C src -j"${JOBS}" libhamlib_la_LDFLAGS="${ldflags}"
  make -C src install libhamlib_la_LDFLAGS="${ldflags}"
  make -C include install
  popd >/dev/null

  local so="${prefix}/lib/libhamlib.so"
  local soname
  soname=$("${TOOLCHAIN}/bin/llvm-readelf" -d "${so}" | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
  if [[ "${soname}" != "libhamlib.so" ]]; then
    echo "Unexpected SONAME '${soname}' in ${so}" >&2
    return 1
  fi
  if "${TOOLCHAIN}/bin/llvm-readelf" -d "${so}" | grep -q 'NEEDED.*libusb'; then
    echo "${so} depends on libusb; it must be built without it" >&2
    return 1
  fi
  # Bionic's symbols are versioned (@LIBC); an unversioned undefined symbol
  # has no provider on the device and would make System.loadLibrary fail.
  local missing
  missing=$("${TOOLCHAIN}/bin/llvm-nm" -D --undefined-only "${so}" | awk '$2 !~ /@/ {print $2}')
  if [[ -n "${missing}" ]]; then
    echo "${so} has unresolved symbols:" >&2
    echo "${missing}" >&2
    return 1
  fi

  mkdir -p "${JNILIBS_DIR}/${abi}"
  "${TOOLCHAIN}/bin/llvm-strip" --strip-unneeded -o "${JNILIBS_DIR}/${abi}/libhamlib.so" "${so}"
  echo "=== ${abi}: $(du -h "${JNILIBS_DIR}/${abi}/libhamlib.so" | cut -f1) -> ${JNILIBS_DIR}/${abi}/libhamlib.so"
}

for abi in ${ABIS}; do
  build_abi "${abi}"
done
echo "Hamlib Android build complete."
