---
name: unity-android-apk
description: Build a Unity or Tuanjie (团结引擎) project into an installable Android APK and verify it. Use when the user asks to build, export, package, or deliver an APK, 安卓安装包, 手机安装包, 手机能用的软件, or an Android app for a Unity project, especially when the project or editor path contains non-ASCII characters. Not for iOS/IPA, WebGL, Google Play AAB release signing, or non-Unity Android apps.
metadata:
  short-description: Build and verify Unity/Tuanjie Android APKs
---

# Unity/Tuanjie Android APK

Turn a Unity project into an APK that installs and launches on a phone, then prove it with package, ABI, SDK and signature checks. A successful editor process by itself is not completion.

## Install

Copy this folder so that `SKILL.md` sits at the skill root:

- `%USERPROFILE%\.codex\skills\unity-android-apk` for every project, or
- `<project>\.codex\skills\unity-android-apk` for one project.

## Use when

- The user says 打包 APK, 导出安卓包, 手机安装包, 安卓版, build an APK, or package the game for Android.
- The project is a Unity 2022.3 LTS or Tuanjie project.
- The project or editor path contains non-ASCII characters and the Android toolchain needs an ASCII path.

## Required environment

- Run every command in **PowerShell**, not a WSL shell.
- Unity or Tuanjie must have Android Build Support with `SDK`, `NDK` and `OpenJDK` under `Editor/Data/PlaybackEngines/AndroidPlayer`.
- The Android toolchain can reject non-ASCII or very long paths. The script creates or reuses ASCII `subst` drives and removes only the mappings it created.
- Build outputs default to `<project>\Builds\<Project>-Android`; never write them inside `Assets/`.

## Fast path

Run the bundled script from PowerShell. It reads product name, bundle id, version, version code and minimum SDK from `ProjectSettings/ProjectSettings.asset` when they are not passed:

```powershell
& '<skill-root>\scripts\Build-AndroidApk.ps1' `
  -ProjectPath 'D:\Games\MyGame'
```

If the editor is not in a standard Unity Hub location, pass it explicitly:

```powershell
& '<skill-root>\scripts\Build-AndroidApk.ps1' `
  -ProjectPath 'D:\Games\MyGame' `
  -EditorPath 'D:\Unity\2022.3.62f1\Editor\Unity.exe'
```

Useful overrides:

```powershell
-ProductName 'Game Name' -BundleId 'com.example.game' -Version '1.0.0' -VersionCode 1
-FriendlyName 'GameName-v1.0.0' -OutputDirectory 'Builds/MyGame-Android'
-Architectures 'armv7,arm64' -MinSdk 22 -Orientation landscape
-IconPath 'Assets/Art/AppIcon.png' -Scenes 'Assets/Scenes/Main.unity'
-KeystorePath 'keystore.jks' -KeystoreAlias 'release' -KeystorePassword '...' -KeyPassword '...'
-Aab -TimeoutMinutes 90 -DryRun
```

`-DryRun` resolves the editor, Android module and mapped paths without building. Use it first when the environment is unfamiliar.

The script prints a JSON summary as its final output. Report the APK path, size, SHA-256, package/version, minimum Android version, ABIs and signing schemes. Offer `adb install -r <apk>` when a device is connected, but do not claim real-device testing unless `adb devices` showed a device and the app launched.

## What the script does

1. Resolves the project, editor and Android module, preferring the editor version in `ProjectVersion.txt`. Search order: `-EditorPath`, `UNITY_HUB_EDITOR_ROOT` / `UNITY_EDITOR_ROOT` / `TUANJIE_HUB_EDITOR_ROOT` / `TUANJIE_EDITOR_ROOT`, standard Unity/Tuanjie Hub folders, then portable editors beside the project's parent folders.
2. Creates or reuses ASCII `subst` mappings for the project and editor install.
3. Installs `Assets/Editor/CodexAndroidBuild.cs` only when it is missing. The file reads build settings from `CODEX_ANDROID_*` environment variables, so the same entry works for future projects. Use `-RefreshAndroidBuildScript` to overwrite it, or `-SkipAndroidBuildScript -BuildMethod 'YourBuild.Entry'` to keep a project-specific entry.
4. Configures package id, version, orientation, ARMv7+ARM64, IL2CPP Release, API 22 minimum, Gradle APK and icon.
5. Waits for `CODEX_ANDROID_BUILD_SUCCESS|...` in the log instead of trusting the launcher process.
6. Verifies with `aapt2 dump badging` and `apksigner verify`, then copies a friendly-named APK.

## Mobile readiness

Before the first Android build of a game, check and fix these in the project:

- Guard desktop-only calls such as `Screen.SetResolution` with `#if !UNITY_ANDROID && !UNITY_IOS`, or remove them.
- On mobile, use `Screen.orientation = ScreenOrientation.AutoRotation` with landscape enabled for a landscape game.
- Make touch/pointer input work; do not depend on hover, right-click or keyboard-only actions.
- Keep UI inside the safe area; do not render under notches or gesture bars.
- Do not rely on `Application.dataPath` or arbitrary file paths being writable; use `persistentDataPath`.
- Keep a 1280x720 or similar landscape reference resolution unless the game is portrait.

If the game only ran in the editor before, state that real-device behavior remains unverified.

## Verification gates

Do not deliver until all are true:

- The APK exists and is larger than 1 MB.
- Package name and `versionName` match the request.
- `sdkVersion` is at or below the phone's Android API; the default is API 22 (Android 5.1).
- `native-code` includes `arm64-v8a` and `armeabi-v7a` unless the user requested a single ABI.
- `apksigner verify` reports at least one verified signature scheme.
- The APK has a launcher activity.

Debug signing is correct for sideloading. State that it is not suitable for Google Play; Play requires a release keystore and an AAB.

## Re-check an APK

```powershell
& '<skill-root>\scripts\Verify-AndroidApk.ps1' `
  -ApkPath 'D:\path\to\game.apk' `
  -ExpectedPackage 'com.example.game' `
  -ExpectedVersion '1.0.0'
```

## Troubleshooting

Read `references/environment.md` for Android module layout, `subst` behavior, license failures, Gradle failures and phone install errors.