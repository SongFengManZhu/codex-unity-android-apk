[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectPath,
    [string]$EditorPath,
    [string]$ProductName,
    [string]$BundleId,
    [string]$Version,
    [int]$VersionCode = 0,
    [string]$FriendlyName,
    [string]$OutputDirectory,
    [string]$BuildMethod = 'CodexAndroidBuild.BuildApk',
    [string]$Architectures = 'armv7,arm64',
    [int]$MinSdk = 0,
    [ValidateSet('landscape', 'portrait', 'auto')]
    [string]$Orientation = 'landscape',
    [string]$IconPath,
    [string]$Scenes,
    [string]$KeystorePath,
    [string]$KeystoreAlias,
    [string]$KeystorePassword,
    [string]$KeyPassword,
    [ValidateSet('il2cpp', 'mono')]
    [string]$ScriptingBackend = 'il2cpp',
    [switch]$Aab,
    [switch]$SkipAndroidBuildScript,
    [switch]$RefreshAndroidBuildScript,
    [int]$TimeoutMinutes = 90,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$script:createdMappings = New-Object System.Collections.Generic.List[string]

function Write-Step {
    param([string]$Message)
    Write-Host "[android-apk] $Message"
}

function Get-ProjectSetting {
    param(
        [string]$SettingsFile,
        [string]$Pattern
    )

    if (!(Test-Path -LiteralPath $SettingsFile)) {
        return $null
    }

    $text = Get-Content -LiteralPath $SettingsFile -Raw
    $match = [regex]::Match($text, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (!$match.Success) {
        return $null
    }

    $value = $match.Groups[1].Value.Trim().Trim('"')
    return [regex]::Unescape($value)
}

function Test-PathUnder {
    param(
        [string]$Path,
        [string]$Root
    )

    $cleanRoot = $Root.TrimEnd('\')
    if ($Path.Equals($cleanRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $Path.StartsWith($cleanRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SubstMappings {
    $result = @()
    $lines = & subst 2>$null
    foreach ($line in $lines) {
        $match = [regex]::Match($line, '^([A-Z]):\\:\s*=>\s*(.+?)\s*$')
        if ($match.Success) {
            $result += [pscustomobject]@{
                Drive = $match.Groups[1].Value
                Target = $match.Groups[2].Value.TrimEnd('\')
            }
        }
    }

    return $result
}

function Get-MappingForRoot {
    param([string]$Root)

    $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $mappings = Get-SubstMappings
    $best = $null

    foreach ($mapping in $mappings) {
        if ((Test-PathUnder $resolved $mapping.Target)) {
            if (!$best -or $mapping.Target.Length -gt $best.Target.Length) {
                $best = $mapping
            }
        }
    }

    if ($best) {
        return [pscustomobject]@{
            Original = $best.Target
            Drive = $best.Drive
            Created = $false
            MappedRoot = ($best.Drive + ':' + $resolved.Substring($best.Target.Length))
        }
    }

    if ($resolved -notmatch '[^\x00-\x7F]') {
        return [pscustomobject]@{
            Original = $resolved
            Drive = $null
            Created = $false
            MappedRoot = $resolved
        }
    }

    $used = @{}
    foreach ($mapping in $mappings) {
        $used[$mapping.Drive] = $true
    }

    $drive = $null
    foreach ($letter in [char[]]'RSTUVWXYZ') {
        $key = [string]$letter
        if (!$used.ContainsKey($key)) {
            $drive = $key
            break
        }
    }

    if (!$drive) {
        throw 'No free drive letter is available for an ASCII subst mapping.'
    }

    & subst "${drive}:" $resolved
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to map '$resolved' to ${drive}:."
    }

    $script:createdMappings.Add($drive)
    return [pscustomobject]@{
        Original = $resolved
        Drive = $drive
        Created = $true
        MappedRoot = "${drive}:"
    }
}

function ConvertTo-MappedPath {
    param(
        [string]$Path,
        $Mapping
    )

    if (!$Mapping.Drive) {
        return $Path
    }

    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = $Mapping.Original.TrimEnd('\')

    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        return "$($Mapping.Drive):\"
    }

    if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return "$($Mapping.Drive):" + $full.Substring($root.Length)
    }

    throw "Path '$full' is not under the mapped root '$root'."
}

function ConvertFrom-MappedPath {
    param(
        [string]$Path,
        $Mapping
    )

    if (!$Mapping.Drive) {
        return $Path
    }

    $prefix = "$($Mapping.Drive):"
    if ($Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        return $Mapping.Original + $Path.Substring($prefix.Length)
    }

    return $Path
}

function Find-EditorPath {
    param(
        [string]$Requested,
        [string]$Project
    )

    if ($Requested) {
        $resolved = Resolve-Path -LiteralPath $Requested -ErrorAction SilentlyContinue
        if (!$resolved) {
            throw "Unity/Tuanjie editor not found: $Requested"
        }
        return $resolved.Path
    }

    $version = $null
    $versionFile = Join-Path $Project 'ProjectSettings\ProjectVersion.txt'
    if (Test-Path -LiteralPath $versionFile) {
        $versionText = Get-Content -LiteralPath $versionFile -Raw
        $versionMatch = [regex]::Match($versionText, '(?m)^m_EditorVersion:\s*(\S+)')
        if ($versionMatch.Success) {
            $version = $versionMatch.Groups[1].Value
        }
    }

    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($envName in @('UNITY_HUB_EDITOR_ROOT', 'UNITY_EDITOR_ROOT', 'TUANJIE_HUB_EDITOR_ROOT', 'TUANJIE_EDITOR_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ($value) {
            $bases.Add($value)
        }
    }
    foreach ($base in @(
        'C:\Program Files\Unity\Hub\Editor',
        'C:\Program Files\Unity Hub\Editor',
        'C:\Program Files\Tuanjie Hub\Editor',
        'C:\Program Files\Tuanjie\Hub\Editor'
    )) {
        $bases.Add($base)
    }
    if ($env:LOCALAPPDATA) {
        $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs\Unity\Hub\Editor'))
        $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs\Tuanjie\Hub\Editor'))
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if ($version) {
        foreach ($base in $bases) {
            $candidates.Add((Join-Path $base "$version\Editor\Tuanjie.exe"))
            $candidates.Add((Join-Path $base "$version\Editor\Unity.exe"))
        }
    }

    $cursor = Split-Path $Project -Parent
    for ($depth = 0; $depth -lt 3 -and $cursor; $depth++) {
        foreach ($sub in @('', 'UnityEditors', 'Editors', 'Tools\Unity')) {
            $root = if ($sub) { Join-Path $cursor $sub } else { $cursor }
            if (!(Test-Path -LiteralPath $root)) {
                continue
            }
            foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                $candidates.Add((Join-Path $directory.FullName 'Editor\Tuanjie.exe'))
                $candidates.Add((Join-Path $directory.FullName 'Editor\Unity.exe'))
            }
        }
        $parent = Split-Path $cursor -Parent
        if (!$parent -or $parent -eq $cursor) {
            break
        }
        $cursor = $parent
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'No Unity/Tuanjie editor was found. Pass -EditorPath explicitly or set UNITY_HUB_EDITOR_ROOT.'
}
function Get-BuildToolDirectory {
    param([string]$AndroidPlayerMapped)

    $root = Join-Path $AndroidPlayerMapped 'SDK\build-tools'
    if (!(Test-Path -LiteralPath $root)) {
        throw "Android build-tools not found under $root"
    }

    $versions = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending

    $selected = $versions | Select-Object -First 1
    if (!$selected) {
        $selected = Get-ChildItem -LiteralPath $root -Directory | Select-Object -First 1
    }

    if (!$selected) {
        throw "No Android build-tools version found under $root"
    }

    return $selected.FullName
}

function Invoke-ApkVerification {
    param(
        [string]$ApkPath,
        [string]$AndroidPlayerMapped,
        [string]$ExpectedPackage,
        [string]$ExpectedVersion
    )

    $buildTools = Get-BuildToolDirectory $AndroidPlayerMapped
    $aapt2 = Join-Path $buildTools 'aapt2.exe'
    $apksigner = Join-Path $buildTools 'apksigner.bat'

    if (!(Test-Path -LiteralPath $aapt2)) {
        throw "aapt2 not found: $aapt2"
    }
    if (!(Test-Path -LiteralPath $apksigner)) {
        throw "apksigner not found: $apksigner"
    }

    $badgingLines = & $aapt2 dump badging $ApkPath 2>&1
    $badgingExit = $LASTEXITCODE
    $badging = $badgingLines -join "`n"
    if ($badgingExit -ne 0) {
        throw "aapt2 could not read the APK:`n$badging"
    }

    $packageMatch = [regex]::Match(
        $badging,
        "package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'")
    if (!$packageMatch.Success) {
        throw "Could not parse package metadata from aapt2 output:`n$badging"
    }

    $package = $packageMatch.Groups[1].Value
    $versionCode = $packageMatch.Groups[2].Value
    $versionName = $packageMatch.Groups[3].Value

    $minSdkMatch = [regex]::Match($badging, "(?m)^sdkVersion:'(\d+)'")
    $targetSdkMatch = [regex]::Match($badging, "(?m)^targetSdkVersion:'(\d+)'")
    $labelMatch = [regex]::Match($badging, "(?m)^application-label:'([^']*)'")
    $activityMatch = [regex]::Match($badging, "(?m)^launchable-activity: name='([^']+)'")

    $abis = @()
    $nativeMatch = [regex]::Match($badging, '(?m)^native-code:\s*(.+)$')
    if ($nativeMatch.Success) {
        $abis = [regex]::Matches($nativeMatch.Groups[1].Value, "'([^']+)'") |
            ForEach-Object { $_.Groups[1].Value }
    }

    if ($ExpectedPackage -and $package -ne $ExpectedPackage) {
        throw "Package mismatch: expected '$ExpectedPackage', found '$package'."
    }
    if ($ExpectedVersion -and $versionName -ne $ExpectedVersion) {
        throw "Version mismatch: expected '$ExpectedVersion', found '$versionName'."
    }
    if (!$activityMatch.Success) {
        throw 'The APK has no launcher activity.'
    }
    if ($abis.Count -eq 0) {
        throw 'The APK has no native-code ABI. It is not a Unity Android player build.'
    }

    $oldJavaHome = $env:JAVA_HOME
    $oldPath = $env:Path
    $env:JAVA_HOME = Join-Path $AndroidPlayerMapped 'OpenJDK'
    $env:Path = "$($env:JAVA_HOME)\bin;$oldPath"

    try {
        $signatureLines = & $apksigner verify --verbose --print-certs $ApkPath 2>&1
        $signatureExit = $LASTEXITCODE
        $signature = $signatureLines -join "`n"
    }
    finally {
        $env:JAVA_HOME = $oldJavaHome
        $env:Path = $oldPath
    }

    if ($signatureExit -ne 0) {
        throw "APK signature verification failed:`n$signature"
    }

    $signedV1 = $signature -match 'Verified using v1 scheme \(JAR signing\): true'
    $signedV2 = $signature -match 'Verified using v2 scheme \(APK Signature Scheme v2\): true'
    $signedV3 = $signature -match 'Verified using v3 scheme \(APK Signature Scheme v3\): true'
    if (!($signedV1 -or $signedV2 -or $signedV3)) {
        throw "APK has no verified signature scheme:`n$signature"
    }

    return [pscustomobject]@{
        Package = $package
        VersionCode = $versionCode
        VersionName = $versionName
        MinSdk = if ($minSdkMatch.Success) { [int]$minSdkMatch.Groups[1].Value } else { $null }
        TargetSdk = if ($targetSdkMatch.Success) { [int]$targetSdkMatch.Groups[1].Value } else { $null }
        Label = if ($labelMatch.Success) { $labelMatch.Groups[1].Value } else { $null }
        LaunchActivity = $activityMatch.Groups[1].Value
        Abis = @($abis)
        SignedV1 = [bool]$signedV1
        SignedV2 = [bool]$signedV2
        SignedV3 = [bool]$signedV3
        DebugSigned = [bool]($signature -match 'CN=Android Debug')
    }
}

try {
    $project = (Resolve-Path -LiteralPath $ProjectPath).Path.TrimEnd('\')
    if (!(Test-Path -LiteralPath (Join-Path $project 'Assets'))) {
        throw "Not a Unity project (Assets folder missing): $project"
    }

    $settingsFile = Join-Path $project 'ProjectSettings\ProjectSettings.asset'
    $projectName = Split-Path $project -Leaf

    $settingsProductName = Get-ProjectSetting $settingsFile '(?m)^\s*productName:\s*(.+?)\s*$'
    $settingsBundleId = Get-ProjectSetting $settingsFile '(?m)^\s*expectedBundleIdentifier:\s*(.+?)\s*$'
    $settingsVersion = Get-ProjectSetting $settingsFile '(?m)^\s*bundleVersion:\s*(.+?)\s*$'
    $settingsVersionCode = Get-ProjectSetting $settingsFile '(?m)^\s*AndroidBundleVersionCode:\s*(\d+)'
    $settingsMinSdk = Get-ProjectSetting $settingsFile '(?m)^\s*AndroidMinSdkVersion:\s*(\d+)'

    if (!$settingsBundleId -and (Test-Path -LiteralPath $settingsFile)) {
        $settingsText = Get-Content -LiteralPath $settingsFile -Raw
        $identifierMatch = [regex]::Match(
            $settingsText,
            '(?ms)^\s*applicationIdentifier:\s*\r?\n\s*Android:\s*(.+?)\s*$')
        if ($identifierMatch.Success) {
            $settingsBundleId = $identifierMatch.Groups[1].Value.Trim().Trim('"')
        }
    }

    if (!$ProductName) {
        $ProductName = if ($settingsProductName) { $settingsProductName } else { $projectName }
    }

    if (!$BundleId) {
        $BundleId = $settingsBundleId
    }
    if (!$BundleId) {
        $asciiProject = ($projectName.ToLowerInvariant() -replace '[^a-z0-9]', '')
        if (!$asciiProject) {
            $asciiProject = 'game'
        }
        $BundleId = "com.example.$asciiProject"
    }
    if ($BundleId -notmatch '^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$') {
        throw "Invalid Android bundle id: $BundleId"
    }

    if (!$Version) {
        $Version = if ($settingsVersion) { $settingsVersion } else { '1.0.0' }
    }
    if ($VersionCode -le 0) {
        $VersionCode = if ($settingsVersionCode) { [int]$settingsVersionCode } else { 1 }
    }
    if ($MinSdk -le 0) {
        $MinSdk = if ($settingsMinSdk) { [int]$settingsMinSdk } else { 22 }
    }
    if ($MinSdk -lt 22) {
        $MinSdk = 22
    }

    $workspaceRoot = $project

    if (!$OutputDirectory) {
        $OutputDirectory = Join-Path $workspaceRoot "Builds\$projectName-Android"
    }
    elseif (![IO.Path]::IsPathRooted($OutputDirectory)) {
        $OutputDirectory = Join-Path $workspaceRoot $OutputDirectory
    }
    $outputDir = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')

    $editor = Find-EditorPath $EditorPath $project
    $editorFolder = Split-Path $editor -Parent
    $androidPlayer = Join-Path $editorFolder 'Data\PlaybackEngines\AndroidPlayer'
    foreach ($required in @('SDK', 'NDK', 'OpenJDK')) {
        if (!(Test-Path -LiteralPath (Join-Path $androidPlayer $required))) {
            throw "Android Build Support is incomplete: missing $required under $androidPlayer"
        }
    }

    $editorInstallRoot = Split-Path $editorFolder -Parent
    $projectMapping = Get-MappingForRoot $project
    $editorMapping = Get-MappingForRoot $editorInstallRoot
    if (!(Test-PathUnder $outputDir $projectMapping.Original)) {
        throw "Output directory must be inside '$($projectMapping.Original)' or use an ASCII path: $outputDir"
    }

    $mappedProject = ConvertTo-MappedPath $project $projectMapping
    $mappedEditor = ConvertTo-MappedPath $editor $editorMapping
    $mappedAndroidPlayer = ConvertTo-MappedPath $androidPlayer $editorMapping
    $mappedOutputDir = ConvertTo-MappedPath $outputDir $projectMapping

    if ($DryRun) {
        $plan = [ordered]@{
            editor = $editor
            androidPlayer = $androidPlayer
            project = $project
            mappedProject = $mappedProject
            mappedEditor = $mappedEditor
            outputDirectory = $outputDir
            mappedOutputDirectory = $mappedOutputDir
            productName = $ProductName
            bundleId = $BundleId
            versionName = $Version
            versionCode = $VersionCode
            minSdk = $MinSdk
            architectures = $Architectures
            orientation = $Orientation
            buildMethod = $BuildMethod
            appBundle = [bool]$Aab
            scriptingBackend = $ScriptingBackend
        }
        Write-Output ($plan | ConvertTo-Json -Depth 6)
        return
    }

    if (!$SkipAndroidBuildScript) {
        $skillRoot = Split-Path $PSScriptRoot -Parent
        $templatePath = Join-Path $skillRoot 'assets\CodexAndroidBuild.cs'
        $targetScript = Join-Path $project 'Assets\Editor\CodexAndroidBuild.cs'

        if (!(Test-Path -LiteralPath $templatePath)) {
            throw "Build template not found: $templatePath"
        }

        if (!(Test-Path -LiteralPath $targetScript) -or $RefreshAndroidBuildScript) {
            $editorDirectory = Split-Path $targetScript -Parent
            New-Item -ItemType Directory -Force -Path $editorDirectory | Out-Null
            $content = Get-Content -LiteralPath $templatePath -Raw
            [IO.File]::WriteAllText($targetScript, $content, (New-Object System.Text.UTF8Encoding($false)))
            Write-Step "Installed build entry: $targetScript"
        }
    }

    New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
    $logDir = Join-Path $project 'Logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $logDir "build-android-$stamp.log"
    $mappedLog = ConvertTo-MappedPath $logPath $projectMapping

    $asciiName = ($projectName -replace '[^A-Za-z0-9_-]', '')
    if (!$asciiName) {
        $asciiName = 'game'
    }
    $extension = if ($Aab) { '.aab' } else { '.apk' }

    $env:CODEX_ANDROID_OUTPUT_DIR = $mappedOutputDir
    $env:CODEX_ANDROID_APK_NAME = $asciiName + $extension
    $env:CODEX_ANDROID_PRODUCT_NAME = $ProductName
    $env:CODEX_ANDROID_BUNDLE_ID = $BundleId
    $env:CODEX_ANDROID_VERSION_NAME = $Version
    $env:CODEX_ANDROID_VERSION_CODE = [string]$VersionCode
    $env:CODEX_ANDROID_MIN_SDK = [string]$MinSdk
    $env:CODEX_ANDROID_ARCHS = $Architectures
    $env:CODEX_ANDROID_ORIENTATION = $Orientation
    $env:CODEX_ANDROID_SCRIPTING_BACKEND = $ScriptingBackend
    $env:CODEX_ANDROID_BUILD_AAB = if ($Aab) { '1' } else { '0' }

    if ($IconPath) { $env:CODEX_ANDROID_ICON = $IconPath }
    if ($Scenes) { $env:CODEX_ANDROID_SCENES = $Scenes }
    if ($KeystorePath) { $env:CODEX_ANDROID_KEYSTORE = $KeystorePath }
    if ($KeystoreAlias) { $env:CODEX_ANDROID_KEYSTORE_ALIAS = $KeystoreAlias }
    if ($KeystorePassword) { $env:CODEX_ANDROID_KEYSTORE_PASSWORD = $KeystorePassword }
    if ($KeyPassword) { $env:CODEX_ANDROID_KEY_PASSWORD = $KeyPassword }

    $env:JAVA_HOME = Join-Path $mappedAndroidPlayer 'OpenJDK'
    $env:ANDROID_HOME = Join-Path $mappedAndroidPlayer 'SDK'
    $env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
    $env:ANDROID_NDK_ROOT = Join-Path $mappedAndroidPlayer 'NDK'
    $env:Path = "$($env:JAVA_HOME)\bin;$($env:ANDROID_HOME)\platform-tools;$env:Path"

    Write-Step "Building $ProductName ($BundleId $Version) with $mappedEditor"
    $editorArguments = @(
        '-batchmode',
        '-quit',
        '-projectPath', "`"$mappedProject`"",
        '-buildTarget', 'Android',
        '-executeMethod', $BuildMethod,
        '-logFile', "`"$mappedLog`""
    )

    $startTime = Get-Date
    $process = Start-Process `
        -FilePath $mappedEditor `
        -ArgumentList $editorArguments `
        -WorkingDirectory (Split-Path $mappedEditor -Parent) `
        -PassThru `
        -WindowStyle Hidden

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $success = $false
    $logText = ''

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2

        if (Test-Path -LiteralPath $mappedLog) {
            $logText = Get-Content -LiteralPath $mappedLog -Raw -ErrorAction SilentlyContinue
        }

        if ($logText -and $logText.Contains('CODEX_ANDROID_BUILD_SUCCESS|')) {
            $success = $true
            break
        }
        if ($logText -and $logText.Contains('CODEX_ANDROID_BUILD_FAILED|')) {
            break
        }

        if ($process.HasExited) {
            Start-Sleep -Seconds 3
            if (Test-Path -LiteralPath $mappedLog) {
                $logText = Get-Content -LiteralPath $mappedLog -Raw -ErrorAction SilentlyContinue
            }
            if ($logText -and $logText.Contains('CODEX_ANDROID_BUILD_SUCCESS|')) {
                $success = $true
                break
            }

            $otherEditors = Get-Process -Name 'Tuanjie', 'Unity' -ErrorAction SilentlyContinue |
                Where-Object { $_.StartTime -ge $startTime.AddSeconds(-5) }
            if (!$otherEditors) {
                break
            }
        }
    }

    if (!$success) {
        if (!$process.HasExited) {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        }

        $tail = ''
        if (Test-Path -LiteralPath $mappedLog) {
            $tail = (Get-Content -LiteralPath $mappedLog -Tail 100) -join "`n"
        }
        throw "Android build did not report success. Log: $logPath`n$tail"
    }

    $marker = [regex]::Match($logText, 'CODEX_ANDROID_BUILD_SUCCESS\|([^|\r\n]+)\|(\d+)')
    if (!$marker.Success) {
        throw "Build succeeded but the output marker could not be parsed. Log: $logPath"
    }

    $builtMappedPath = $marker.Groups[1].Value.Trim()
    $apkPath = ConvertFrom-MappedPath $builtMappedPath $projectMapping
    if (!(Test-Path -LiteralPath $apkPath)) {
        $apkPath = Join-Path $outputDir (Split-Path $builtMappedPath -Leaf)
    }
    if (!(Test-Path -LiteralPath $apkPath)) {
        throw "Build reported success but the output file was not found: $builtMappedPath"
    }

    Write-Step 'Verifying package, ABI, SDK levels and signature'
    $verification = Invoke-ApkVerification `
        -ApkPath $apkPath `
        -AndroidPlayerMapped $mappedAndroidPlayer `
        -ExpectedPackage $BundleId `
        -ExpectedVersion $Version

    $size = (Get-Item -LiteralPath $apkPath).Length
    $hash = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash

    $friendlyBase = if ($FriendlyName) { $FriendlyName } else { "$ProductName-v$Version" }
    $friendlyBase = $friendlyBase -replace '\.(apk|aab)$', ''
    $friendlyBase = $friendlyBase -replace '[:：/\\*?"<>|]', '-'
    $friendlyBase = $friendlyBase.Trim()
    if (!$friendlyBase) {
        $friendlyBase = "$($projectName)-v$Version"
    }

    $friendlyPath = Join-Path $outputDir ($friendlyBase + $extension)
    if ($friendlyPath -ne $apkPath) {
        Copy-Item -LiteralPath $apkPath -Destination $friendlyPath -Force
    }

    $summary = [ordered]@{
        apk = $friendlyPath
        rawApk = $apkPath
        sizeMB = [math]::Round($size / 1MB, 2)
        sha256 = $hash
        package = $verification.Package
        versionName = $verification.VersionName
        versionCode = $verification.VersionCode
        label = $verification.Label
        minSdk = $verification.MinSdk
        targetSdk = $verification.TargetSdk
        abis = @($verification.Abis)
        launchActivity = $verification.LaunchActivity
        signedV1 = $verification.SignedV1
        signedV2 = $verification.SignedV2
        signedV3 = $verification.SignedV3
        debugSigned = $verification.DebugSigned
        buildLog = $logPath
    }

    Write-Step "APK ready: $friendlyPath"
    Write-Output ($summary | ConvertTo-Json -Depth 6)
}
finally {
    foreach ($drive in $script:createdMappings) {
        & subst "${drive}:" /D 2>$null | Out-Null
    }
}
