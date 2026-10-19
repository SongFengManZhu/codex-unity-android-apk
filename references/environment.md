# Android Build Environment

Read this when the build script fails or the editor/SDK layout is unfamiliar.

## Editor and Android module locations

| OS | Typical editor | AndroidPlayer |
| --- | --- | --- |
| Windows | `C:\Program Files\Unity\Hub\Editor\<version>\Editor\Unity.exe` | `<editor>\Data\PlaybackEngines\AndroidPlayer` |
| Linux | `~/Unity/Hub/Editor/<version>/Editor/Unity` or `/opt/unity/editors/<version>/Editor/Unity` | `<editor>\Data\PlaybackEngines\AndroidPlayer` |
| macOS | `/Applications/Unity/Hub/Editor/<version>/Unity.app/Contents/MacOS/Unity` | `Unity.app/Contents/PlaybackEngines/AndroidPlayer` |

Tuanjie installs use the same layout with `Tuanjie.exe` / `Tuanjie` / `Tuanjie.app`.

`AndroidPlayer` must contain:

```text
SDK\
  platforms\android-<api>
  build-tools\<version>\
  platform-tools\adb.exe
NDK\
OpenJDK\
```

The script refuses to build when `SDK`, `NDK` or `OpenJDK` is missing.

## Editor discovery order

1. Explicit editor path (`-EditorPath` / `--editor`)
2. Environment variables: `UNITY_HUB_EDITOR_ROOT`, `UNITY_EDITOR_ROOT`, `TUANJIE_HUB_EDITOR_ROOT`, `TUANJIE_EDITOR_ROOT`
3. Standard Hub folders under `Program Files`, `/Applications`, `~/Unity/Hub/Editor`, `~/Applications`, `/opt`
4. Portable editors in the project's parent folders (`UnityEditors`, `Editors`, `Tools/Unity`, or the parent itself)

If discovery still fails, pass the editor path explicitly.

## Windows: why `subst` is used

Gradle, NDK and IL2CPP toolchains can fail when the project or editor path contains non-ASCII characters or is very long. The PowerShell script:

- reuses an existing mapping when one already covers the path;
- creates a free drive from `R:` to `Z:` when needed;
- removes only the mappings it created in the current run.

Example:

```powershell
subst R: "D:\Games\MyGame"
subst S: "D:\Unity\2022.3.62f1"
```

Do not delete a mapping that existed before the run. macOS and Linux handle UTF-8 paths natively, so the bash script does not use `subst`.

## Manual build command

Windows (PowerShell):

```powershell
& 'S:\Editor\Unity.exe' -batchmode -quit `
  -projectPath 'R:\MyGame' `
  -buildTarget Android `
  -executeMethod CodexAndroidBuild.BuildApk `
  -logFile 'R:\MyGame\Logs\build-android-<stamp>.log'
```

macOS / Linux (bash):

```bash
"/Applications/Unity/Hub/Editor/2022.3.62f1/Unity.app/Contents/MacOS/Unity" \
  -batchmode -quit \
  -projectPath "$HOME/Games/MyGame" \
  -buildTarget Android \
  -executeMethod CodexAndroidBuild.BuildApk \
  -logFile "$HOME/Games/MyGame/Logs/build-android-<stamp>.log"
```

Success markers in the log:

```text
Build succeeded.
CODEX_ANDROID_BUILD_SUCCESS|<path>|<bytes>
```

Failure marker:

```text
CODEX_ANDROID_BUILD_FAILED|<exception>
```

## Failure modes

### Editor exits before building

- Another editor instance has the project open. Close the GUI editor or use a different project.
- The license is missing or expired. Open Unity Hub / Tuanjie Hub, sign in and refresh the license. Batchmode cannot activate a new license.
- The Android module is incomplete. Check that `SDK`, `NDK` and `OpenJDK` all exist under `AndroidPlayer`.
- On macOS, confirm the editor is executable and the app bundle is not quarantined (`xattr -dr com.apple.quarantine <Unity.app>`).

### `Gradle build failed`

- Inspect the log for the first `FAILURE:` line, not the final stack trace.
- Confirm `SDK/platforms/android-<api>` and a `SDK/build-tools/<version>` exist.
- Confirm `JAVA_HOME` points to `AndroidPlayer/OpenJDK`, not a system Java.
- Network or proxy failures usually appear while resolving Gradle dependencies. Retry once; if it persists, inspect the proxy settings used by the editor.
- Non-ASCII or very long paths are a common cause on Windows. Build through the mapped `R:`/`S:` paths.
- On Linux, missing 32-bit libraries or `libGL` can stop the editor before the build starts; check the editor log.

### APK is produced but will not install

- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: an older build with a different signature is installed. Uninstall the old app, then install again.
- `INSTALL_FAILED_NO_MATCHING_ABIS`: the phone does not match the built ABIs. Build `armv7,arm64`.
- `INSTALL_FAILED_OLDER_SDK`: the phone is older than the minimum API. The default is API 22.
- `INSTALL_PARSE_FAILED_NO_CERTIFICATES`: re-run the verify script; the APK is unsigned or corrupted.
- `App not installed` after transferring by chat or cloud: compare SHA-256 after the transfer; some channels rename or truncate files.

### Device checks

```bash
ADB="<AndroidPlayer>/SDK/platform-tools/adb"
"$ADB" devices
"$ADB" install -r "/path/to/game.apk"
```

On Windows use `adb.exe`. If `adb devices` is empty, enable USB debugging, use a data cable, and accept the RSA fingerprint prompt on the phone.

## Signing

The default build uses the Android debug certificate. It installs by sideloading but is not accepted for Google Play. For a release build, pass the keystore options; use `-Aab` / `--aab` only when the store requires an Android App Bundle.

## Cleanup

Temporary `subst` drives are removed automatically on Windows. Build logs stay under `<project>/Logs`, and APKs stay under `<project>/Builds`.