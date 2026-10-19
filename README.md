# Unity Android APK · Codex 技能

把 Unity / 团结引擎（Tuanjie）项目打包成**手机可直接安装的 APK**，并自动验证包名、版本、ABI、最低 Android 版本和签名。

这是一个 [Codex](https://github.com/openai/codex) 技能，也可以直接当作 PowerShell 构建脚本使用。

## 能力

- 自动查找 Unity / Tuanjie 编辑器与 Android 模块（SDK、NDK、OpenJDK）
- 自动处理中文或过长路径（通过临时 ASCII `subst` 盘符）
- 从 `ProjectSettings.asset` 读取产品名、包名、版本和版本号
- 默认输出 ARMv7 + ARM64、IL2CPP Release、Gradle APK、最低 API 22
- 构建后用 `aapt2` 与 `apksigner` 验证包名、版本、ABI、SDK 和签名
- 支持 Debug 签名侧载，也支持传入 release keystore
- 支持 `-DryRun` 先检查环境，不真正构建

## 安装为 Codex 技能

把整个仓库放到以下任一位置，确保 `SKILL.md` 位于技能根目录：

- 全局：`%USERPROFILE%\.codex\skills\unity-android-apk`
- 单项目：`<项目>\.codex\skills\unity-android-apk`

```powershell
git clone https://github.com/<your-name>/codex-unity-android-apk `
  "$env:USERPROFILE\.codex\skills\unity-android-apk"
```

之后在 Codex 里说“把这个游戏打包成手机能安装的 APK”即可触发。

## 环境要求

- Windows + PowerShell 5.1 或 7
- Unity 2022.3 LTS 或 Tuanjie 1.x
- 已安装 **Android Build Support**，且以下目录存在：
  - `Editor\Data\PlaybackEngines\AndroidPlayer\SDK`
  - `Editor\Data\PlaybackEngines\AndroidPlayer\NDK`
  - `Editor\Data\PlaybackEngines\AndroidPlayer\OpenJDK`

## 快速开始

```powershell
& '.\scripts\Build-AndroidApk.ps1' -ProjectPath 'D:\Games\MyGame'
```

编辑器不在标准 Unity Hub 目录时：

```powershell
& '.\scripts\Build-AndroidApk.ps1' `
  -ProjectPath 'D:\Games\MyGame' `
  -EditorPath 'D:\Unity\2022.3.62f1\Editor\Unity.exe'
```

先检查环境、不构建：

```powershell
& '.\scripts\Build-AndroidApk.ps1' -ProjectPath 'D:\Games\MyGame' -DryRun
```

## 常用参数

| 参数 | 说明 |
| --- | --- |
| `-ProjectPath` | Unity 项目目录（必填） |
| `-EditorPath` | Unity/Tuanjie 编辑器路径 |
| `-ProductName` | 应用显示名称 |
| `-BundleId` | Android 包名，如 `com.example.game` |
| `-Version` / `-VersionCode` | 版本名 / 版本号 |
| `-FriendlyName` | 输出 APK 的文件名 |
| `-OutputDirectory` | 输出目录，默认 `<项目>\Builds\<项目名>-Android` |
| `-Architectures` | 默认 `armv7,arm64` |
| `-MinSdk` | 默认 22（Android 5.1） |
| `-Orientation` | `landscape` / `portrait` / `auto` |
| `-IconPath` / `-Scenes` | 图标 / 场景列表 |
| `-KeystorePath` 等 | release 签名 |
| `-Aab` | 输出 Android App Bundle |
| `-DryRun` | 只解析环境并打印计划 |

## 输出

构建成功后脚本输出 JSON 摘要，包含：

- APK 路径、大小、SHA-256
- 包名、版本名、版本号
- 最低 / 目标 SDK
- ABI 列表
- 启动 Activity
- v1/v2/v3 签名状态
- 构建日志路径

默认输出示例：`<项目>\Builds\<项目名>-Android\<产品名>-v1.0.0.apk`

## 单独验证 APK

```powershell
& '.\scripts\Verify-AndroidApk.ps1' `
  -ApkPath 'D:\path\to\game.apk' `
  -ExpectedPackage 'com.example.game' `
  -ExpectedVersion '1.0.0'
```

## 常见问题

包名冲突、Gradle 失败、许可证失效、手机安装报错等，见 [references/environment.md](references/environment.md)。

## 许可

MIT