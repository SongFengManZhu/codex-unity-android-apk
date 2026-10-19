#!/usr/bin/env bash
set -euo pipefail

PROJECT=""
EDITOR=""
PRODUCT_NAME=""
BUNDLE_ID=""
VERSION=""
VERSION_CODE="0"
FRIENDLY_NAME=""
OUTPUT_DIR=""
BUILD_METHOD="CodexAndroidBuild.BuildApk"
ARCHITECTURES="armv7,arm64"
MIN_SDK="0"
ORIENTATION="landscape"
ICON=""
SCENES=""
KEYSTORE=""
KEYSTORE_ALIAS=""
KEYSTORE_PASSWORD=""
KEY_PASSWORD=""
SCRIPTING_BACKEND="il2cpp"
AAB=0
SKIP_BUILD_SCRIPT=0
REFRESH_BUILD_SCRIPT=0
TIMEOUT_MINUTES=90
DRY_RUN=0

step() { printf '[android-apk] %s\n' "$*"; }
die() { printf '[android-apk] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: Build-AndroidApk.sh --project <path> [options]

Options:
  --project, -p <path>       Unity project directory (required)
  --editor <path>            Unity/Tuanjie executable
  --product-name <name>      Application display name
  --bundle-id <id>           Android package id (com.example.game)
  --version <name>           Version name (1.0.0)
  --version-code <n>         Version code
  --friendly-name <name>     Output file base name
  --output <dir>             Output directory (default <project>/Builds/<project>-Android)
  --architectures <list>     armv7,arm64 (default)
  --min-sdk <n>              Minimum Android API (default 22)
  --orientation <value>      landscape|portrait|auto
  --icon <path>              Icon path relative to the project
  --scenes <list>            Comma-separated scene paths
  --keystore <path>          Release keystore
  --keystore-alias <name>    Keystore alias
  --keystore-password <pw>   Keystore password
  --key-password <pw>        Key password
  --scripting-backend <v>    il2cpp|mono
  --aab                      Build an Android App Bundle instead of an APK
  --skip-build-script        Do not install CodexAndroidBuild.cs
  --refresh-build-script     Overwrite an existing CodexAndroidBuild.cs
  --timeout-minutes <n>      Build timeout (default 90)
  --dry-run                  Print the resolved plan and exit
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --project|-p) PROJECT="$2"; shift 2 ;;
        --editor) EDITOR="$2"; shift 2 ;;
        --product-name) PRODUCT_NAME="$2"; shift 2 ;;
        --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --version-code) VERSION_CODE="$2"; shift 2 ;;
        --friendly-name) FRIENDLY_NAME="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --architectures) ARCHITECTURES="$2"; shift 2 ;;
        --min-sdk) MIN_SDK="$2"; shift 2 ;;
        --orientation) ORIENTATION="$2"; shift 2 ;;
        --icon) ICON="$2"; shift 2 ;;
        --scenes) SCENES="$2"; shift 2 ;;
        --keystore) KEYSTORE="$2"; shift 2 ;;
        --keystore-alias) KEYSTORE_ALIAS="$2"; shift 2 ;;
        --keystore-password) KEYSTORE_PASSWORD="$2"; shift 2 ;;
        --key-password) KEY_PASSWORD="$2"; shift 2 ;;
        --scripting-backend) SCRIPTING_BACKEND="$2"; shift 2 ;;
        --aab) AAB=1; shift ;;
        --skip-build-script) SKIP_BUILD_SCRIPT=1; shift ;;
        --refresh-build-script) REFRESH_BUILD_SCRIPT=1; shift ;;
        --timeout-minutes) TIMEOUT_MINUTES="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -n "$PROJECT" ]] || { usage; die "--project is required"; }
[[ -d "$PROJECT" ]] || die "Project directory not found: $PROJECT"
PROJECT="$(cd "$PROJECT" && pwd)"
[[ -d "$PROJECT/Assets" ]] || die "Not a Unity project (Assets folder missing): $PROJECT"
PROJECT_NAME="$(basename "$PROJECT")"

SETTINGS="$PROJECT/ProjectSettings/ProjectSettings.asset"

settings_value() {
    local key="$1"
    [[ -f "$SETTINGS" ]] || return 0
    awk -v key="$key" '
        $0 ~ "^[[:space:]]*" key ":" {
            sub("^[[:space:]]*" key ":[[:space:]]*", "");
            gsub(/^"|"$/, "");
            print; exit
        }' "$SETTINGS" | tr -d "\r"
}

settings_bundle_id() {
    local value
    value="$(settings_value expectedBundleIdentifier)"
    if [[ -n "$value" ]]; then printf '%s\n' "$value"; return; fi
    [[ -f "$SETTINGS" ]] || return 0
    awk '
        /^[[:space:]]*applicationIdentifier:/ { flag=1; next }
        flag && /^[[:space:]]*Android:/ {
            sub(/^[[:space:]]*Android:[[:space:]]*/, "");
            gsub(/^"|"$/, "");
            print; exit
        }
        flag && /^[^[:space:]]/ { flag=0 }
    ' "$SETTINGS" | tr -d "\r"
}

find_editor() {
    local version="$1"
    local os
    os="$(uname -s)"

    if [[ -n "$EDITOR" ]]; then
        [[ -f "$EDITOR" ]] || die "Editor not found: $EDITOR"
        printf '%s\n' "$EDITOR"
        return
    fi

    local roots=()
    local var value
    for var in UNITY_HUB_EDITOR_ROOT UNITY_EDITOR_ROOT TUANJIE_HUB_EDITOR_ROOT TUANJIE_EDITOR_ROOT; do
        value="${!var:-}"
        [[ -n "$value" ]] && roots+=("$value")
    done

    if [[ "$os" == "Darwin" ]]; then
        roots+=("$HOME/Applications/Unity/Hub/Editor" "/Applications/Unity/Hub/Editor" "/Applications/Tuanjie/Hub/Editor" "$HOME/Applications/Tuanjie/Hub/Editor")
    else
        roots+=("$HOME/Unity/Hub/Editor" "/opt/Unity/Hub/Editor" "/opt/unity/editors" "/opt/Tuanjie/Hub/Editor")
    fi

    local candidates=()
    if [[ -n "$version" ]]; then
        local root
        for root in "${roots[@]}"; do
            candidates+=("$root/$version/Editor/Unity" "$root/$version/Editor/Tuanjie")
            candidates+=("$root/$version/Unity.app/Contents/MacOS/Unity" "$root/$version/Tuanjie.app/Contents/MacOS/Tuanjie")
        done
    fi

    local cursor="$PROJECT"
    local depth sub dir
    for depth in 1 2 3; do
        cursor="$(dirname "$cursor")"
        [[ -d "$cursor" ]] || break
        for sub in "" "UnityEditors" "Editors" "Tools/Unity"; do
            if [[ -n "$sub" ]]; then dir="$cursor/$sub"; else dir="$cursor"; fi
            [[ -d "$dir" ]] || continue
            while IFS= read -r -d '' candidate; do
                candidates+=("$candidate")
            done < <(find "$dir" -maxdepth 5 \( -name Unity -o -name Tuanjie \) -type f -perm -u+x -print0 2>/dev/null)
        done
        [[ "$cursor" == "/" || "$cursor" == "$HOME" ]] && break
    done

    local candidate
    if (( ${#candidates[@]} > 0 )); then
        for candidate in "${candidates[@]}"; do
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate"
                return
            fi
        done
    fi

    die "No Unity/Tuanjie editor found. Pass --editor or set UNITY_HUB_EDITOR_ROOT."
}

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
        if [[ -d "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
    printf '\n'
}

build_tools_dir() {
    local android="$1"
    local root="$android/SDK/build-tools"
    [[ -d "$root" ]] || die "Android build-tools not found under $root"
    local latest
    latest="$(find "$root" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*.[0-9]*.[0-9]*' 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
    if [[ -z "$latest" ]]; then
        latest="$(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1)"
    fi
    [[ -n "$latest" ]] || die "No build-tools version found under $root"
    printf '%s\n' "$latest"
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

SETTINGS_PRODUCT="$(settings_value productName)"
SETTINGS_BUNDLE="$(settings_bundle_id)"
SETTINGS_VERSION="$(settings_value bundleVersion)"
SETTINGS_VERSION_CODE="$(settings_value AndroidBundleVersionCode)"
SETTINGS_MIN_SDK="$(settings_value AndroidMinSdkVersion)"

[[ -n "$PRODUCT_NAME" ]] || PRODUCT_NAME="${SETTINGS_PRODUCT:-$PROJECT_NAME}"
if [[ -z "$BUNDLE_ID" ]]; then BUNDLE_ID="$SETTINGS_BUNDLE"; fi
if [[ -z "$BUNDLE_ID" ]]; then
    ascii_project="$(printf '%s' "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
    [[ -n "$ascii_project" ]] || ascii_project="game"
    BUNDLE_ID="com.example.$ascii_project"
fi
[[ -n "$VERSION" ]] || VERSION="${SETTINGS_VERSION:-1.0.0}"
if [[ "$VERSION_CODE" -le 0 ]]; then VERSION_CODE="${SETTINGS_VERSION_CODE:-1}"; fi
if [[ "$MIN_SDK" -le 0 ]]; then MIN_SDK="${SETTINGS_MIN_SDK:-22}"; fi
[[ "$MIN_SDK" -ge 22 ]] || MIN_SDK=22

VERSION_TEXT="$(grep -m1 '^m_EditorVersion:' "$PROJECT/ProjectSettings/ProjectVersion.txt" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)"
EDITOR_PATH="$(find_editor "$VERSION_TEXT")"
EDITOR_FOLDER="$(dirname "$EDITOR_PATH")"
ANDROID_PLAYER="$(android_player_for "$EDITOR_PATH")"
[[ -n "$ANDROID_PLAYER" ]] || die "AndroidPlayer not found for editor: $EDITOR_PATH"
for required in SDK NDK OpenJDK; do
    [[ -d "$ANDROID_PLAYER/$required" ]] || die "Android Build Support is incomplete: missing $required under $ANDROID_PLAYER"
done

if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$PROJECT/Builds/$PROJECT_NAME-Android"
elif [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$PROJECT/$OUTPUT_DIR"
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '{\n'
    printf '  "editor": "%s",\n' "$EDITOR_PATH"
    printf '  "androidPlayer": "%s",\n' "$ANDROID_PLAYER"
    printf '  "project": "%s",\n' "$PROJECT"
    printf '  "outputDirectory": "%s",\n' "$OUTPUT_DIR"
    printf '  "productName": "%s",\n' "$PRODUCT_NAME"
    printf '  "bundleId": "%s",\n' "$BUNDLE_ID"
    printf '  "versionName": "%s",\n' "$VERSION"
    printf '  "versionCode": %s,\n' "$VERSION_CODE"
    printf '  "minSdk": %s,\n' "$MIN_SDK"
    printf '  "architectures": "%s",\n' "$ARCHITECTURES"
    printf '  "appBundle": %s\n' "$([[ $AAB -eq 1 ]] && echo true || echo false)"
    printf '}\n'
    exit 0
fi

SKILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$SKILL_ROOT/assets/CodexAndroidBuild.cs"
TARGET_SCRIPT="$PROJECT/Assets/Editor/CodexAndroidBuild.cs"
if [[ ! -f "$TEMPLATE" ]]; then die "Build template not found: $TEMPLATE"; fi
if [[ "$SKIP_BUILD_SCRIPT" -eq 0 ]]; then
    if [[ ! -f "$TARGET_SCRIPT" || "$REFRESH_BUILD_SCRIPT" -eq 1 ]]; then
        mkdir -p "$(dirname "$TARGET_SCRIPT")"
        cp "$TEMPLATE" "$TARGET_SCRIPT"
        step "Installed build entry: $TARGET_SCRIPT"
    fi
fi

mkdir -p "$PROJECT/Logs"
LOG="$PROJECT/Logs/build-android-$(date +%Y%m%d-%H%M%S).log"
EXT=".apk"
[[ "$AAB" -eq 1 ]] && EXT=".aab"
ASCII_NAME="$(printf '%s' "$PROJECT_NAME" | tr -cd 'A-Za-z0-9_-')"
[[ -n "$ASCII_NAME" ]] || ASCII_NAME="game"

export CODEX_ANDROID_OUTPUT_DIR="$OUTPUT_DIR"
export CODEX_ANDROID_APK_NAME="$ASCII_NAME$EXT"
export CODEX_ANDROID_PRODUCT_NAME="$PRODUCT_NAME"
export CODEX_ANDROID_BUNDLE_ID="$BUNDLE_ID"
export CODEX_ANDROID_VERSION_NAME="$VERSION"
export CODEX_ANDROID_VERSION_CODE="$VERSION_CODE"
export CODEX_ANDROID_MIN_SDK="$MIN_SDK"
export CODEX_ANDROID_ARCHS="$ARCHITECTURES"
export CODEX_ANDROID_ORIENTATION="$ORIENTATION"
export CODEX_ANDROID_SCRIPTING_BACKEND="$SCRIPTING_BACKEND"
export CODEX_ANDROID_BUILD_AAB="$([[ $AAB -eq 1 ]] && echo 1 || echo 0)"
[[ -n "$ICON" ]] && export CODEX_ANDROID_ICON="$ICON"
[[ -n "$SCENES" ]] && export CODEX_ANDROID_SCENES="$SCENES"
[[ -n "$KEYSTORE" ]] && export CODEX_ANDROID_KEYSTORE="$KEYSTORE"
[[ -n "$KEYSTORE_ALIAS" ]] && export CODEX_ANDROID_KEYSTORE_ALIAS="$KEYSTORE_ALIAS"
[[ -n "$KEYSTORE_PASSWORD" ]] && export CODEX_ANDROID_KEYSTORE_PASSWORD="$KEYSTORE_PASSWORD"
[[ -n "$KEY_PASSWORD" ]] && export CODEX_ANDROID_KEY_PASSWORD="$KEY_PASSWORD"

export JAVA_HOME="$ANDROID_PLAYER/OpenJDK"
export ANDROID_HOME="$ANDROID_PLAYER/SDK"
export ANDROID_SDK_ROOT="$ANDROID_HOME"
export ANDROID_NDK_ROOT="$ANDROID_PLAYER/NDK"
export PATH="$JAVA_HOME/bin:$ANDROID_HOME/platform-tools:$PATH"

step "Building $PRODUCT_NAME ($BUNDLE_ID $VERSION) with $EDITOR_PATH"
"$EDITOR_PATH" -batchmode -quit -projectPath "$PROJECT" -buildTarget Android \
    -executeMethod "$BUILD_METHOD" -logFile "$LOG" &
BUILD_PID=$!

DEADLINE=$(( $(date +%s) + TIMEOUT_MINUTES * 60 ))
SUCCESS=0
while (( $(date +%s) < DEADLINE )); do
    sleep 2
    if [[ -f "$LOG" ]]; then
        grep -q 'CODEX_ANDROID_BUILD_SUCCESS|' "$LOG" && { SUCCESS=1; break; }
        grep -q 'CODEX_ANDROID_BUILD_FAILED|' "$LOG" && break
    fi
    if ! kill -0 "$BUILD_PID" 2>/dev/null; then
        sleep 3
        grep -q 'CODEX_ANDROID_BUILD_SUCCESS|' "$LOG" 2>/dev/null && SUCCESS=1
        break
    fi
done

if [[ "$SUCCESS" -ne 1 ]]; then
    kill "$BUILD_PID" 2>/dev/null || true
    [[ -f "$LOG" ]] && tail -n 100 "$LOG" >&2
    die "Android build did not report success. Log: $LOG"
fi

MARKER="$(grep -o 'CODEX_ANDROID_BUILD_SUCCESS|[^|]*|[0-9]*' "$LOG" | tail -n1)"
BUILT_PATH="${MARKER#*|}"
BUILT_PATH="${BUILT_PATH%|*}"
[[ -f "$BUILT_PATH" ]] || BUILT_PATH="$OUTPUT_DIR/$(basename "$BUILT_PATH")"
[[ -f "$BUILT_PATH" ]] || die "Build reported success but output was not found: $BUILT_PATH"

step "Verifying package, ABI, SDK levels and signature"
BT="$(build_tools_dir "$ANDROID_PLAYER")"
AAPT2="$BT/aapt2"
[[ -x "$AAPT2" ]] || AAPT2="$BT/aapt2.exe"
APKSIGNER="$BT/apksigner"
[[ -x "$APKSIGNER" ]] || APKSIGNER="$BT/apksigner.bat"
[[ -x "$AAPT2" ]] || die "aapt2 not found: $AAPT2"
[[ -f "$APKSIGNER" ]] || die "apksigner not found: $APKSIGNER"

BADGING="$("$AAPT2" dump badging "$BUILT_PATH" 2>&1)" || die "aapt2 failed: $BADGING"
PKG="$(printf '%s\n' "$BADGING" | sed -n "s/^package: name='\([^']*\)'.*/\1/p" | head -n1)"
VNAME="$(printf '%s\n' "$BADGING" | sed -n "s/^package:.*versionName='\([^']*\)'.*/\1/p" | head -n1)"
VCODE="$(printf '%s\n' "$BADGING" | sed -n "s/^package:.*versionCode='\([^']*\)'.*/\1/p" | head -n1)"
MINSDK="$(printf '%s\n' "$BADGING" | sed -n "s/^sdkVersion:'\([0-9]*\)'.*/\1/p" | head -n1)"
TARGETSDK="$(printf '%s\n' "$BADGING" | sed -n "s/^targetSdkVersion:'\([0-9]*\)'.*/\1/p" | head -n1)"
LABEL="$(printf '%s\n' "$BADGING" | sed -n "s/^application-label:'\([^']*\)'.*/\1/p" | head -n1)"
ACTIVITY="$(printf '%s\n' "$BADGING" | sed -n "s/^launchable-activity: name='\([^']*\)'.*/\1/p" | head -n1)"
ABIS="$(printf '%s\n' "$BADGING" | sed -n 's/^native-code: //p' | head -n1)"

[[ "$PKG" == "$BUNDLE_ID" ]] || die "Package mismatch: expected '$BUNDLE_ID', found '$PKG'."
[[ "$VNAME" == "$VERSION" ]] || die "Version mismatch: expected '$VERSION', found '$VNAME'."
[[ -n "$ACTIVITY" ]] || die "The APK has no launcher activity."
[[ -n "$ABIS" ]] || die "The APK has no native-code ABI."

SIG="$("$APKSIGNER" verify --verbose --print-certs "$BUILT_PATH" 2>&1)" || die "Signature verification failed: $SIG"
SIG_V1=0; SIG_V2=0; SIG_V3=0; DEBUG_SIGNED=0
grep -q 'Verified using v1 scheme.*true' <<<"$SIG" && SIG_V1=1
grep -q 'Verified using v2 scheme.*true' <<<"$SIG" && SIG_V2=1
grep -q 'Verified using v3 scheme.*true' <<<"$SIG" && SIG_V3=1
grep -q 'CN=Android Debug' <<<"$SIG" && DEBUG_SIGNED=1
[[ $((SIG_V1 + SIG_V2 + SIG_V3)) -gt 0 ]] || die "APK has no verified signature scheme."

FRIENDLY="${FRIENDLY_NAME:-$PRODUCT_NAME-v$VERSION}"
FRIENDLY="${FRIENDLY%.apk}"; FRIENDLY="${FRIENDLY%.aab}"
FRIENDLY="$(printf '%s' "$FRIENDLY" | tr '/:*?"<>|' '----------' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
[[ -n "$FRIENDLY" ]] || FRIENDLY="$PROJECT_NAME-v$VERSION"
FRIENDLY_PATH="$OUTPUT_DIR/$FRIENDLY$EXT"
if [[ "$FRIENDLY_PATH" != "$BUILT_PATH" ]]; then
    cp -f "$BUILT_PATH" "$FRIENDLY_PATH"
fi

SIZE_BYTES="$(wc -c < "$FRIENDLY_PATH" | tr -d ' ')"
SIZE_MB="$(awk -v b="$SIZE_BYTES" 'BEGIN { printf "%.2f", b/1048576 }')"
SHA="$(sha256_of "$FRIENDLY_PATH")"

if command -v python3 >/dev/null 2>&1; then
    python3 - "$FRIENDLY_PATH" "$SIZE_MB" "$SHA" "$PKG" "$VNAME" "$VCODE" "$MINSDK" "$TARGETSDK" "$LABEL" "$ACTIVITY" "$ABIS" "$SIG_V1" "$SIG_V2" "$SIG_V3" "$DEBUG_SIGNED" "$LOG" <<'PY'
import json, sys
keys = ["apk","sizeMB","sha256","package","versionName","versionCode","minSdk","targetSdk","label","launchActivity","abis","signedV1","signedV2","signedV3","debugSigned","buildLog"]
values = sys.argv[1:]
data = dict(zip(keys, values))
data["sizeMB"] = float(data["sizeMB"])
for k in ("minSdk","targetSdk"):
    data[k] = int(data[k]) if data[k] else None
data["abis"] = data["abis"].replace("'", "").split()
for k in ("signedV1","signedV2","signedV3","debugSigned"):
    data[k] = data[k] == "1"
print(json.dumps(data, ensure_ascii=False, indent=2))
PY
else
    printf 'apk=%s\nsizeMB=%s\nsha256=%s\npackage=%s\nversionName=%s\nversionCode=%s\nminSdk=%s\ntargetSdk=%s\nabis=%s\nsignedV1=%s\nsignedV2=%s\nsignedV3=%s\ndebugSigned=%s\nbuildLog=%s\n' \
        "$FRIENDLY_PATH" "$SIZE_MB" "$SHA" "$PKG" "$VNAME" "$VCODE" "$MINSDK" "$TARGETSDK" "$ABIS" "$SIG_V1" "$SIG_V2" "$SIG_V3" "$DEBUG_SIGNED" "$LOG"
fi

step "APK ready: $FRIENDLY_PATH"