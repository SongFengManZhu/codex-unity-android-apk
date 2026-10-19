# Unity Android APK · Codex 技能

把 Unity / 团结引擎（Tuanjie）项目打包成**手机可直接安装的 APK**，并自动验证包名、版本、ABI、最低 Android 版本和签名。

这是一个 [Codex](https://github.com/openai/codex) 技能，也可以直接当作构建脚本使用。

## 支持的系统

| 系统 | 脚本 | 状态 |
| --- | --- | --- |
| Windows 10/11 | `scripts/Build-AndroidApk.ps1` | 已在 Windows 实机验证 |
| macOS | `scripts/Build-AndroidApk.sh` | 同一构建流程，脚本已做语法检查 |
| Linux | `scripts/Build-AndroidApk.sh` | 同一构建流程，脚本已做语法检查 |

Windows 版会自动用 ASCII `subst` 盘符绕开中文/超长路径；macOS 与 Linux 原生支持 UTF-8 路径，不需要 `subst`。

## 能力

- 自动查找 Unity / Tuanjie 编辑器与 Android 模块（SDK、NDK、OpenJDK）
- 自动读取 `ProjectSettings.asset` 里的产品名、包名、版本和版本号
- 默认输出 ARMv7 + ARM64、IL2CPP Release、Gradle APK、最低 API 22
- 构建后用 `aapt2` 与 `apksigner` 验证包名、版本、ABI、SDK 和签名
- 支持 Debug 签名侧载，也支持传入 release keystore
- 支持 `--dry-run` / `-DryRun` 先检查环境，不真正构建

## 安装为 Codex 技能

把整个仓库放到以下任一位置，确保 `SKILL.md` 位于技能根目录：

- 全局：`%USERPROFILE%\.codex\skills\unity-android-apk`（Windows）
- 全局：`~/.codex/skills/unity-android-apk`（macOS / Linux）
- 单项目：`<项目>/.codex/skills/unity-android-apk`

```bash
git clone https://github.com/SongFengManZhu/codex-unity-android-apk \
  ~/.codex/skills/unity-android-apk
```

之后在 Codex 里说“把这个游戏打包成手机能安装的 APK”即可触发。

## 环境要求

- Unity 2022.3 LTS 或 Tuanjie 1.x
- 已安装 **Android Build Support**，且以下目录存在：
  - `SDK`
  - `NDK`
  - `OpenJDK`
  - 它们位于 `AndroidPlayer` 下（Windows/Linux 在 `Editor/Data/PlaybackEngines/AndroidPlayer`，macOS 在 `Unity.app/Contents/PlaybackEngines/AndroidPlayer`）
- Windows 用 PowerShell 5.1 或 7；macOS / Linux 用 bash 3.2+

## 快速开始

### Windows

```powershell
& '.\scripts\Build-AndroidApk.ps1' -ProjectPath 'D:\Games\MyGame'
```

先检查环境、不构建：

```powershell
& '.\scripts\Build-AndroidApk.ps1' -ProjectPath 'D:\Games\MyGame' -DryRun
```

### macOS / Linux

```bash
chmod +x scripts/*.sh
./scripts/Build-AndroidApk.sh --project "$HOME/Games/MyGame"
```

先检查环境、不构建：

```bash
./scripts/Build-AndroidApk.sh --project "$HOME/Games/MyGame" --dry-run
```

编辑器不在标准 Unity Hub 目录时：

```bash
./scripts/Build-AndroidApk.sh \
  --project "$HOME/Games/MyGame" \
  --editor "/Applications/Unity/Hub/Editor/2022.3.62f1/Unity.app/Contents/MacOS/Unity"
```

## 常用参数

| PowerShell | bash | 说明 |
| --- | --- | --- |
| `-ProjectPath` | `--project, -p` | Unity 项目目录（必填） |
| `-EditorPath` | `--editor` | Unity/Tuanjie 编辑器路径 |
| `-ProductName` | `--product-name` | 应用显示名称 |
| `-BundleId` | `--bundle-id` | Android 包名，如 `com.example.game` |
| `-Version` / `-VersionCode` | `--version` / `--version-code` | 版本名 / 版本号 |
| `-FriendlyName` | `--friendly-name` | 输出 APK 的文件名 |
| `-OutputDirectory` | `--output` | 输出目录，默认 `<项目>/Builds/<项目名>-Android` |
| `-Architectures` | `--architectures` | 默认 `armv7,arm64` |
| `-MinSdk` | `--min-sdk` | 默认 22（Android 5.1） |
| `-Orientation` | `--orientation` | `landscape` / `portrait` / `auto` |
| `-IconPath` / `-Scenes` | `--icon` / `--scenes` | 图标 / 场景列表 |
| `-KeystorePath` 等 | `--keystore` 等 | release 签名 |
| `-Aab` | `--aab` | 输出 Android App Bundle |
| `-DryRun` | `--dry-run` | 只解析环境并打印计划 |

## 输出

构建成功后输出 JSON 摘要，包含：

- APK 路径、大小、SHA-256
- 包名、版本名、版本号
- 最低 / 目标 SDK
- ABI 列表
- 启动 Activity
- v1/v2/v3 签名状态
- 构建日志路径

默认输出示例：`<项目>/Builds/<项目名>-Android/<产品名>-v1.0.0.apk`

## 单独验证 APK

Windows：

```powershell
& '.\scripts\Verify-AndroidApk.ps1' `
  -ApkPath 'D:\path\to\game.apk' `
  -ExpectedPackage 'com.example.game' `
  -ExpectedVersion '1.0.0'
```

macOS / Linux：

```bash
./scripts/Verify-AndroidApk.sh \
  --apk "$HOME/path/to/game.apk" \
  --expected-package com.example.game \
  --expected-version 1.0.0
```

## 常见问题

包名冲突、Gradle 失败、许可证失效、手机安装报错、各系统的编辑器路径等，见 [references/environment.md](references/environment.md)。

## 许可

MIT