#!/usr/bin/env bash
set -euo pipefail

APK=""
EDITOR=""
ANDROID_PLAYER=""
EXPECTED_PACKAGE=""
EXPECTED_VERSION=""

step() { printf '[android-apk] %s\n' "$*"; }
die() { printf '[android-apk] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: Verify-AndroidApk.sh --apk <path> [options]

Options:
  --apk <path>               APK or AAB to verify (required)
  --editor <path>            Unity/Tuanjie executable (used to locate SDK tools)
  --android-player <path>    AndroidPlayer directory (SDK/NDK/OpenJDK)
  --expected-package <id>    Expected Android package id
  --expected-version <name>  Expected versionName
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk) APK="$2"; shift 2 ;;
        --editor) EDITOR="$2"; shift 2 ;;
        --android-player) ANDROID_PLAYER="$2"; shift 2 ;;
        --expected-package) EXPECTED_PACKAGE="$2"; shift 2 ;;
        --expected-version) EXPECTED_VERSION="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -n "$APK" ]] || { usage; die "--apk is required"; }
[[ -f "$APK" ]] || die "APK not found: $APK"
APK="$(cd "$(dirname "$APK")" && pwd)/$(basename "$APK")"

android_player_for() {
    local editor="$1"
    local dir parent grand
    dir="$(dirname "$editor")"
    parent="$(dirname "$dir")"
    grand="$(dirname "$parent")"
    local candidate
    for candidate in \
        "$dir/Data/PlaybackEngines/AndroidPlayer" \
        "$parent/PlaybackEngines/AndroidPlayer" \
        "$grand/PlaybackEngines/AndroidPlayer"; do
        if [[ -d "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
    done
    printf '\n'
}

find_android_player() {
    if [[ -n "$ANDROID_PLAYER" ]]; then
        [[ -d "$ANDROID_PLAYER" ]] || die "AndroidPlayer not found: $ANDROID_PLAYER"
        printf '%s\n' "$ANDROID_PLAYER"
        return
    fi

    if [[ -n "$EDITOR" ]]; then
        local player
        player="$(android_player_for "$EDITOR")"
        [[ -n "$player" ]] || die "AndroidPlayer not found for editor: $EDITOR"
        printf '%s\n' "$player"
        return
    fi

    local os roots=() root found
    os="$(uname -s)"
    if [[ "$os" == "Darwin" ]]; then
        roots+=("/Applications/Unity/Hub/Editor" "/Applications/Tuanjie/Hub/Editor" "$HOME/Applications/Unity/Hub/Editor")
    else
        roots+=("$HOME/Unity/Hub/Editor" "/opt/Unity/Hub/Editor" "/opt/unity/editors" "/opt/Tuanjie/Hub/Editor")
    fi

    for root in "${roots[@]}"; do
        [[ -d "$root" ]] || continue
        while IFS= read -r -d '' candidate; do
            if [[ -d "$candidate" ]]; then printf '%s\n' "$candidate"; return; fi
        done < <(find "$root" -maxdepth 6 -type d -name AndroidPlayer -print0 2>/dev/null)
    done
    die "AndroidPlayer not found. Pass --editor or --android-player."
}

build_tools_dir() {
    local android="$1"
    local root="$android/SDK/build-tools"
    [[ -d "$root" ]] || die "Android build-tools not found under $root"
    local latest
    latest="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
    [[ -n "$latest" ]] || latest="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
    [[ -n "$latest" ]] || die "No build-tools version found under $root"
    printf '%s\n' "$latest"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

ANDROID_PLAYER="$(find_android_player)"
BT="$(build_tools_dir "$ANDROID_PLAYER")"
AAPT2="$BT/aapt2"
[[ -x "$AAPT2" ]] || AAPT2="$BT/aapt2.exe"
APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || APKSIGNER="$BT/apksigner.bat"
[[ -x "$AAPT2" ]] || die "aapt2 not found: $AAPT2"
[[ -f "$APKSIGNER" ]] || die "apksigner not found: $APKSIGNER"

BADGING="$("$AAPT2" dump badging "$APK" 2>&1)" || die "aapt2 failed: $BADGING"
PKG="$(printf '%s\n' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1)"
VNAME="$(printf '%s\n' "$BADGING" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p" | head -n1)"
VCODE="$(printf '%s\n' "$BADGING" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p" | head -n1)"
MINSDK="$(printf '%s\n' "$BADGING" | sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p" | head -n1)"
TARGETSDK="$(printf '%s\n' "$BADGING" | sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" | head -n1)"
LABEL="$(printf '%s\n' "$BADGING" | sed -n "s/^application-label:'\([^']*\)'.*/\1/p" | head -n1)"
ACTIVITY="$(printf '%s\n' "$BADGING" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p" | head -n1)"
ABIS="$(printf '%s\n' "$BADGING" | sed -n 's/^native-code: //p' | head -n1)"

[[ -z "$EXPECTED_PACKAGE" || "$PKG" == "$EXPECTED_PACKAGE" ]] || die "Package mismatch: expected '$EXPECTED_PACKAGE', found '$PKG'."
[[ -z "$EXPECTED_VERSION" || "$VNAME" == "$EXPECTED_VERSION" ]] || die "Version mismatch: expected '$EXPECTED_VERSION', found '$VNAME'."
[[ -n "$ACTIVITY" ]] || die "The APK has no launcher activity."
[[ -n "$ABIS" ]] || die "The APK has no native-code ABI."

export JAVA_HOME="$ANDROID_PLAYER/OpenJDK"
export PATH="$JAVA_HOME/bin:$PATH"
SIG="$("$APKSIGNER" verify --verbose --print-certs "$APK" 2>&1)" || die "Signature verification failed: $SIG"
SIG_V1=0; SIG_V2=0; SIG_V3=0; DEBUG_SIGNED=0
grep -q 'Verified using v1 scheme.*true' <<<"$SIG" && SIG_V1=1
grep -q 'Verified using v2 scheme.*true' <<<"$SIG" && SIG_V2=1
grep -q 'Verified using v3 scheme.*true' <<<"$SIG" && SIG_V3=1
grep -q 'CN=Android Debug' <<<"$SIG" && DEBUG_SIGNED=1
[[ $((SIG_V1 + SIG_V2 + SIG_V3)) -gt 0 ]] || die "APK has no verified signature scheme."

SIZE_BYTES="$(wc -c < "$APK" | tr -d ' ')"
SIZE_MB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b/1048576 }')"
SHA="$(sha256_of "$APK")"

if command -v python3 >/dev/null 2>&1; then
    python3 - "$APK" "$SIZE_MB" "$SHA" "$PKG" "$VNAME" "$VCODE" "$MINSDK" "$TARGETSDK" "$LABEL" "$ACTIVITY" "$ABIS" "$SIG_V1" "$SIG_V2" "$SIG_V3" "$DEBUG_SIGNED" <<'PY'
import json, sys
keys = ["apk","sizeMB","sha256","package","versionName","versionCode","minSdk","targetSdk","label","launchActivity","abis","signedV1","signedV2","signedV3","debugSigned"]
data = dict(zip(keys, sys.argv[1:]))
data["sizeMB"] = float(data["sizeMB"])
for k in ("minSdk","targetSdk"):
    data[k] = int(data[k]) if data[k] else None
data["abis"] = data["abis"].replace("'", "").split()
for k in ("signedV1","signedV2","signedV3","debugSigned"):
    data[k] = data[k] == "1"
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
else
    printf 'apk=%s\nsizeMB=%s\nsha256=%s\npackage=%s\nversionName=%s\nversionCode=%s\nminSdk=%s\ntargetSdk=%s\nabis=%s\nsignedV1=%s\nsignedV2=%s\nsignedV3=%s\ndebugSigned=%s\n' \
        "$APK" "$SIZE_MB" "$SHA" "$PKG" "$VNAME" "$VCODE" "$MINSDK" "$TARGETSDK" "$ABIS" "$SIG_V1" "$SIG_V2" "$SIG_V3" "$DEBUG_SIGNED"
fi