# Android Build Environment

Read this when the build script fails or the editor/SDK layout is unfamiliar.

## Required Android module layout

Android Build Support must be installed for the editor you use:

```text
<EditorRoot>\
  Editor\
    Tuanjie.exe or Unity.exe
    Data\PlaybackEngines\AndroidPlayer\
      SDK\
        platforms\android-<api>
        build-tools\<version>\
        platform-tools\adb.exe
      NDK\
      OpenJDK\
```

The script refuses to build when `SDK`, `NDK` or `OpenJDK` is missing.

## Editor discovery order

1. `-EditorPath`
2. Environment variables: `UNITY_HUB_EDITOR_ROOT`, `UNITY_EDITOR_ROOT`, `TUANJIE_HUB_EDITOR_ROOT`, `TUANJIE_EDITOR_ROOT`
3. Standard Hub folders under `C:\Program Files` and `%LOCALAPPDATA%\Programs`
4. Portable editors in the project's parent folders (`UnityEditors`, `Editors`, `Tools\Unity`, or the parent itself)

If discovery still fails, pass `-EditorPath` explicitly.

## Why `subst` is used

Gradle, NDK and IL2CPP toolchains can fail when the project or editor path contains non-ASCII characters or is very long. The build script:

- reuses an existing mapping when one already covers the path;
- creates a free drive from `R:` to `Z:` when needed;
- removes only the mappings it created in the current run.

Example:

```powershell
subst R: "D:\Games\MyGame"
subst S: "D:\Unity\2022.3.62f1"
```

Do not delete a mapping that existed before the run.

## Manual build command

The script ultimately runs the equivalent of:

```powershell
& 'S:\Editor\Unity.exe' -batchmode -quit `
  -projectPath 'R:\MyGame' `
  -buildTarget Android `
  -executeMethod CodexAndroidBuild.BuildApk `
  -logFile 'R:\MyGame\Logs\build-android-<stamp>.log'
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

### `Gradle build failed`

- Inspect the log for the first `FAILURE:` line, not the final stack trace.
- Confirm `SDK\platforms\android-<api>` and a `SDK\build-tools\<version>` exist.
- Confirm `JAVA_HOME` points to `AndroidPlayer\OpenJDK`, not a system Java.
- Network or proxy failures usually appear while resolving Gradle dependencies. Retry once; if it persists, inspect the proxy settings used by the editor.
- Non-ASCII or very long paths are a common cause. Build through the mapped `R:`/`S:` paths.

### APK is produced but will not install

- `INSTALL_FAILED_UPDATE_INCOMPATIBLE`: an older build with a different signature is installed. Uninstall the old app, then install again.
- `INSTALL_FAILED_NO_MATCHING_ABIS`: the phone does not match the built ABIs. Build `armv7,arm64`.
- `INSTALL_FAILED_OLDER_SDK`: the phone is older than the minimum API. The default is API 22.
- `INSTALL_PARSE_FAILED_NO_CERTIFICATES`: re-run `Verify-AndroidApk.ps1`; the APK is unsigned or corrupted.
- `App not installed` after transferring by chat or cloud: compare SHA-256 after the transfer; some channels rename or truncate files.

### Device checks

```powershell
$adb = '<EditorRoot>\Editor\Data\PlaybackEngines\AndroidPlayer\SDK\platform-tools\adb.exe'
& $adb devices
& $adb install -r 'D:\path\to\game.apk'
```

If `adb devices` is empty, enable USB debugging, use a data cable, and accept the RSA fingerprint prompt on the phone.

## Signing

The default build uses the Android debug certificate. It installs by sideloading but is not accepted for Google Play. For a release build, pass `-KeystorePath`, `-KeystoreAlias`, `-KeystorePassword` and `-KeyPassword`; use `-Aab` only when the store requires an Android App Bundle.

## Cleanup

Temporary `subst` drives are removed automatically. Build logs stay under `<project>\Logs`, and APKs stay under `<project>\Builds`.