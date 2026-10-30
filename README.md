# Hamlib for Android (Repeaters for Dummies)

Repeaters for Dummies uses a patched build of
[Hamlib](https://github.com/Hamlib/Hamlib), shipped as its own shared
library (`libhamlib.so`) inside the Android app. This folder contains
everything needed to rebuild that library and replace it in the app, as
required by the GNU Lesser General Public License, version 2.1 or later
([COPYING.LIB](COPYING.LIB)).

The patches and the build script in this folder are released under the
same license as Hamlib, LGPL-2.1-or-later.

## Base revision

Hamlib master, commit `1b2461aba99f0dde0531e1732c00e60aeee40657`
(2026-02-23, "Cope with new amplifier code"). It reports version
`5.0.0~git`. It is not a tagged release: Hamlib tags releases on release
branches, and the nearest one is 4.7.0 (2026-02-15), whose branch left
master on 2025-12-02, 143 commits before this revision.

## Patches

| Patch | What it does |
|---|---|
| `0001-android-usb-serial-bridge.patch` | Adds the `android-usb:<deviceId>:<portIndex>` serial path. Hamlib gets one end of a socketpair as the port's fd; two threads move bytes between the other end and callbacks the app registers with `rpt_usb_serial_register()` (new public header `hamlib/rpt_usb_serial.h`). Hooks `serial_open`, `serial_flush`, `ser_close`, `ser_set_rts`, `ser_set_dtr`, and keeps `parse_hoststr` from treating the path as a network address. |
| `0002-android-microham-stub-glob.patch` | Bionic has no `glob()` before API 28; microHam device discovery is stubbed out on Android. |
| `0003-android-rig-no-pthread-cancel.patch` | Bionic has no `pthread_cancel()`; the async-data and morse threads are joined instead. |
| `0004-android-ars-no-pthread-cancel.patch` | Same for the ARS rotator backend. |
| `0005-android-rot-reg-no-androidsensor.patch` | The "androidsensor" rotator is only built by Hamlib's legacy `Android.mk`; with autotools its registration left `initrots5_androidsensor` undefined, so `libhamlib.so` would not load. |

The serial hook in 0001, and patches 0002 to 0004, are based on the
Android USB serial bridge from JS8Android, used under the LGPL . The bridge itself (`src/android_serial_bridge.c`) was
rewritten: it takes the host callbacks through a registered table so
`libhamlib.so` has no undefined symbols, drops the Bluetooth transport,
and serializes open/close so an unplugged device cannot crash the app.

## Building

Requirements: macOS or Linux, the Android NDK, git, and autotools
(`autoconf`, `automake`, GNU `libtool`; on macOS `brew install autoconf
automake libtool`).

```bash
export ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/28.2.13676358
./build-hamlib-android.sh                 # all ABIs
ABIS=arm64-v8a ./build-hamlib-android.sh  # one ABI
```

The script clones Hamlib into `.work/`, checks out the pinned revision,
applies `patches/*.patch`, configures with `--enable-shared
--disable-static --without-libusb` for API 26, and writes `libhamlib.so`
(SONAME `libhamlib.so`) to `jniLibs/<abi>/` (inside the app's source tree it
goes straight into the app's `android/app/src/main/jniLibs/<abi>/`; set
`JNILIBS_DIR` to put it anywhere else). It stops if the library has any
unresolved symbols or depends on libusb.

## Replacing the library in the app

The app loads `libhamlib.so` with `System.loadLibrary("hamlib")` and calls
only Hamlib's public C API plus `rpt_usb_serial_register()`. To use your
own build, replace `lib/<abi>/libhamlib.so` inside the APK with a library
built from these patches (or your own modified version that keeps that
function), then re-sign the APK.
