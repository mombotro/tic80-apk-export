#!/usr/bin/env bash
# Build a standalone Android APK from a TIC-80 cart.
#
# The APK is TIC-80's own Android app, built from source, with:
#   - your cart bundled inside and launched on start
#   - the TIC-80 splash skipped
#   - editors and the SURF game browser compiled out (no CLOSE GAME, no IDE)
#   - your app name, package id and icon
#
# Usage:
#   scripts/build-apk.sh --cart game.tic --name "My Game" \
#       --app-id com.me.mygame --icon icon.png [--out out] [--pro]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# TIC-80 commit the patches were written and tested against.
TIC80_REF="${TIC80_REF:-4c56ee272a6a5d14225df573bd883672e2e0cf38}"

CART="" NAME="" APP_ID="" ICON="" OUT="$PWD/out" WORK="$PWD/work" PRO="OFF"
KEYSTORE="" COMPILE_SDK="${COMPILE_SDK:-}" NDK_VERSION="${NDK_VERSION:-}"

usage() { sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --cart)     CART="$2"; shift 2 ;;
        --name)     NAME="$2"; shift 2 ;;
        --app-id)   APP_ID="$2"; shift 2 ;;
        --icon)     ICON="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --work)     WORK="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --pro)      PRO="ON"; shift ;;
        -h|--help)  usage 0 ;;
        *)          echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

[ -f "$CART" ] || die "--cart must be an existing .tic file"
[ -n "$NAME" ] || die "--name is required"
[[ "$APP_ID" =~ ^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+$ ]] || die "--app-id must look like com.you.game (lowercase)"
[ -z "$ICON" ] || [ -f "$ICON" ] || die "--icon file not found: $ICON"

# Android SDK
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$SDK" ]; then
    for guess in "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
        [ -d "$guess" ] && SDK="$guess" && break
    done
fi
[ -d "$SDK" ] || die "Android SDK not found. Set ANDROID_HOME."
export ANDROID_HOME="$SDK"

command -v java >/dev/null || die "java not found (JDK 17 or newer)"
command -v git  >/dev/null || die "git not found"
command -v python3 >/dev/null || die "python3 not found"
[ -d "$SDK/cmake" ] || die "no CMake in the SDK. Install it: sdkmanager 'cmake;3.22.1'"

# Newest installed NDK unless NDK_VERSION is set.
if [ -z "$NDK_VERSION" ]; then
    NDK_VERSION="$(ls "$SDK/ndk" 2>/dev/null | sort -V | tail -1)"
fi
[ -n "$NDK_VERSION" ] && [ -d "$SDK/ndk/$NDK_VERSION" ] || die "no NDK in the SDK. Install it: sdkmanager 'ndk;27.1.12297006'"

# compileSdk: 34 if installed, otherwise the newest platform.
if [ -z "$COMPILE_SDK" ]; then
    if [ -d "$SDK/platforms/android-34" ]; then
        COMPILE_SDK=34
    else
        COMPILE_SDK="$(ls "$SDK/platforms" 2>/dev/null | sed -n 's/^android-\([0-9][0-9]*\)$/\1/p' | sort -n | tail -1)"
    fi
fi
[ -n "$COMPILE_SDK" ] || die "no Android platform installed. Install one: sdkmanager 'platforms;android-34'"

mkdir -p "$OUT" "$WORK"
OUT="$(cd "$OUT" && pwd)"
WORK="$(cd "$WORK" && pwd)"
CART="$(cd "$(dirname "$CART")" && pwd)/$(basename "$CART")"
[ -z "$ICON" ] || ICON="$(cd "$(dirname "$ICON")" && pwd)/$(basename "$ICON")"

echo "==> SDK $SDK | NDK $NDK_VERSION | compileSdk $COMPILE_SDK | PRO=$PRO"

# 1. TIC-80 source at a pinned commit
SRC="$WORK/TIC-80"
if [ ! -d "$SRC/.git" ]; then
    echo "==> Fetching TIC-80 $TIC80_REF"
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin https://github.com/nesbox/TIC-80.git
    git -C "$SRC" fetch -q --depth 1 origin "$TIC80_REF"
    git -C "$SRC" checkout -q FETCH_HEAD
    git -C "$SRC" submodule update --init --recursive --depth 1
fi

# 2. Reset to a clean tree, then patch
git -C "$SRC" checkout -q -- .
git -C "$SRC" clean -qfd -e vendor -e build/android/app/.cxx -e build/android/.gradle
for p in "$REPO_DIR"/patches/*.patch; do
    echo "==> Applying $(basename "$p")"
    git -C "$SRC" apply "$p"
done

ANDROID="$SRC/build/android"

# 3. Gradle, manifest strings, SDK location
SLUG="$(echo "$NAME" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9-')"
KEYSTORE="${KEYSTORE:-$OUT/$SLUG.keystore}"
PWFILE="${KEYSTORE%.keystore}-password.txt"

python3 - "$ANDROID" "$NAME" "$APP_ID" "$NDK_VERSION" "$COMPILE_SDK" "$PRO" <<'PY'
import sys, re, pathlib
android, name, app_id, ndk, sdk, pro = sys.argv[1:7]
a = pathlib.Path(android)

def sub(path, old, new, count=1):
    s = path.read_text()
    if old not in s:
        sys.exit(f"edit failed, text not found in {path.name}: {old[:60]}")
    path.write_text(s.replace(old, new, count))

g = a / "app/build.gradle"
sub(g, "compileSdkVersion 31", f"compileSdkVersion {sdk}")
sub(g, 'ndkVersion "23.2.8568313"', f'ndkVersion "{ndk}"')
s = g.read_text()
s = re.sub(r"targetSdkVersion 31[^\n]*", f"targetSdkVersion {sdk}", s)
s = s.replace("APP_PLATFORM=android-31", f"APP_PLATFORM=android-{sdk}")
s = re.sub(r'applicationId\(ticEditors == .OFF. \? "[^"]+" : "[^"]+"\)', f'applicationId "{app_id}"', s)
g.write_text(s)
# Newer NDK clang turns old-C mistakes and deprecations in TIC-80 and its
# vendored code into errors (TIC-80 builds with -Werror).
sub(g, "            cmake {\n                arguments \"-DBUILD_PRO",
    '            cmake {\n                cFlags "-Wno-error=implicit-function-declaration", '
    '"-Wno-error=int-conversion", "-Wno-error=incompatible-function-pointer-types", '
    '"-Wno-error=deprecated-declarations"\n'
    '                arguments "-DBUILD_PRO')
# No SURF browser: it carries the CLOSE GAME menu item.
sub(g, '"-DBUILD_EDITORS=${ticEditors}",', '"-DBUILD_EDITORS=${ticEditors}",\n                            "-DBUILD_SURF=OFF",')

safe = name.replace("&", "&amp;").replace("<", "&lt;").replace("'", "\\'")
sub(a / "app/src/main/res/values/strings.xml", "<string name=\"app_name\">TIC-80</string>",
    f'<string name="app_name">{safe}</string>')
PY
echo "sdk.dir=$SDK" > "$ANDROID/local.properties"

# 4. Cart
mkdir -p "$ANDROID/app/src/main/assets"
cp "$CART" "$ANDROID/app/src/main/assets/cart.tic"

# 5. Icon
if [ -n "$ICON" ]; then
    echo "==> Writing launcher icons"
    for spec in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
        dir="$ANDROID/app/src/main/res/mipmap-${spec%%:*}"
        px="${spec#*:}"
        if command -v sips >/dev/null; then
            sips -s format png -z "$px" "$px" "$ICON" --out "$dir/ic_launcher.png" >/dev/null
        elif command -v magick >/dev/null; then
            magick "$ICON" -resize "${px}x${px}!" "$dir/ic_launcher.png"
        elif command -v convert >/dev/null; then
            convert "$ICON" -resize "${px}x${px}!" "$dir/ic_launcher.png"
        else
            die "need sips (macOS) or ImageMagick to resize the icon"
        fi
    done
fi

# 6. Signing key. Keep it: an update must be signed with the same key.
if [ ! -f "$KEYSTORE" ]; then
    echo "==> Creating signing key $KEYSTORE"
    command -v keytool >/dev/null || die "keytool not found (comes with the JDK)"
    PW="$(openssl rand -hex 12)"
    keytool -genkeypair -keystore "$KEYSTORE" -alias release -keyalg RSA -keysize 2048 \
        -validity 10000 -storepass "$PW" -keypass "$PW" -dname "CN=$NAME" >/dev/null 2>&1
    printf '%s\n' "$PW" > "$PWFILE"
    chmod 600 "$PWFILE"
fi
[ -f "$PWFILE" ] || die "keystore exists but $PWFILE is missing. Put the password in that file."
PW="$(head -1 "$PWFILE")"
sed -i.bak "s|^RELEASE_STORE_FILE=.*|RELEASE_STORE_FILE=$KEYSTORE|; s|^RELEASE_KEY_ALIAS=.*|RELEASE_KEY_ALIAS=release|" "$ANDROID/gradle.properties"
rm -f "$ANDROID/gradle.properties.bak"

# 7. Build
echo "==> Building (the first run takes several minutes)"
export RELEASE_STORE_PASSWORD="$PW" RELEASE_KEY_PASSWORD="$PW"
( cd "$ANDROID" && chmod +x gradlew && ./gradlew assembleRelease -PEDITORS=OFF -PPRO="$PRO" )

APK="$OUT/$SLUG.apk"
cp "$ANDROID/app/build/outputs/apk/release/app-release.apk" "$APK"

echo
echo "Built $APK"
echo "Install: adb install -r \"$APK\""
echo "Keep:    $KEYSTORE and $PWFILE (needed to sign updates)"
