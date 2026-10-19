[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ApkPath,
    [string]$EditorPath,
    [string]$ExpectedPackage,
    [string]$ExpectedVersion
)

$ErrorActionPreference = 'Stop'
$createdMappings = New-Object System.Collections.Generic.List[string]

function Test-PathUnder {
    param([string]$Path, [string]$Root)
    $cleanRoot = $Root.TrimEnd('\')
    if ($Path.Equals($cleanRoot, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $Path.StartsWith($cleanRoot + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Get-SubstMappings {
    $result = @()
    foreach ($line in (& subst 2>$null)) {
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

function Get-AsciiMapping {
    param([string]$Root)
    $resolved = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $mappings = Get-SubstMappings
    $best = $null
    foreach ($mapping in $mappings) {
        if ((Test-PathUnder $resolved $mapping.Target)) {
            if (!$best -or $mapping.Target.Length -gt $best.Target.Length) { $best = $mapping }
        }
    }
    if ($best) {
        return [pscustomobject]@{ Original = $best.Target; Drive = $best.Drive }
    }
    if ($resolved -notmatch '[^\x00-\x7F]') {
        return [pscustomobject]@{ Original = $resolved; Drive = $null }
    }
    $used = @{}
    foreach ($mapping in $mappings) { $used[$mapping.Drive] = $true }
    $drive = $null
    foreach ($letter in [char[]]'RSTUVWXYZ') {
        if (!$used.ContainsKey([string]$letter)) { $drive = [string]$letter; break }
    }
    if (!$drive) { throw 'No free drive letter for an ASCII subst mapping.' }
    & subst "${drive}:" $resolved
    if ($LASTEXITCODE -ne 0) { throw "Failed to map '$resolved' to ${drive}:." }
    $script:createdMappings.Add($drive)
    return [pscustomobject]@{ Original = $resolved; Drive = $drive }
}

function ConvertTo-MappedPath {
    param([string]$Path, $Mapping)
    if (!$Mapping.Drive) { return $Path }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = $Mapping.Original.TrimEnd('\')
    if ($full.Equals($root, [StringComparison]::OrdinalIgnoreCase)) { return "$($Mapping.Drive):\" }
    if ($full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        return "$($Mapping.Drive):" + $full.Substring($root.Length)
    }
    throw "Path '$full' is not under '$root'."
}

function Find-EditorPath {
    param([string]$Requested, [string]$ApkPath)

    if ($Requested) {
        $resolved = Resolve-Path -LiteralPath $Requested -ErrorAction SilentlyContinue
        if (!$resolved) { throw "Editor not found: $Requested" }
        return $resolved.Path
    }

    $bases = New-Object System.Collections.Generic.List[string]
    foreach ($envName in @('UNITY_HUB_EDITOR_ROOT', 'UNITY_EDITOR_ROOT', 'TUANJIE_HUB_EDITOR_ROOT', 'TUANJIE_EDITOR_ROOT')) {
        $value = [Environment]::GetEnvironmentVariable($envName)
        if ($value) { $bases.Add($value) }
    }
    foreach ($base in @(
        'C:\Program Files\Unity\Hub\Editor',
        'C:\Program Files\Unity Hub\Editor',
        'C:\Program Files\Tuanjie Hub\Editor',
        'C:\Program Files\Tuanjie\Hub\Editor'
    )) { $bases.Add($base) }
    if ($env:LOCALAPPDATA) {
        $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs\Unity\Hub\Editor'))
        $bases.Add((Join-Path $env:LOCALAPPDATA 'Programs\Tuanjie\Hub\Editor'))
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($base in $bases) {
        if (!(Test-Path -LiteralPath $base)) { continue }
        foreach ($directory in (Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
            foreach ($name in @('Tuanjie.exe', 'Unity.exe')) {
                $candidates.Add((Join-Path $directory.FullName "Editor\$name"))
            }
        }
    }

    $cursor = Split-Path $ApkPath -Parent
    for ($depth = 0; $depth -lt 3 -and $cursor; $depth++) {
        foreach ($sub in @('', 'UnityEditors', 'Editors', 'Tools\Unity')) {
            $root = if ($sub) { Join-Path $cursor $sub } else { $cursor }
            if (!(Test-Path -LiteralPath $root)) { continue }
            foreach ($directory in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
                $candidates.Add((Join-Path $directory.FullName 'Editor\Tuanjie.exe'))
                $candidates.Add((Join-Path $directory.FullName 'Editor\Unity.exe'))
            }
        }
        $parent = Split-Path $cursor -Parent
        if (!$parent -or $parent -eq $cursor) { break }
        $cursor = $parent
    }

    foreach ($candidate in $candidates) {
        $androidPlayer = Join-Path (Split-Path $candidate -Parent) 'Data\PlaybackEngines\AndroidPlayer'
        if ((Test-Path -LiteralPath $candidate) -and (Test-Path -LiteralPath $androidPlayer)) {
            return $candidate
        }
    }

    throw 'No Unity/Tuanjie editor found. Pass -EditorPath or set UNITY_HUB_EDITOR_ROOT.'
}
function Get-BuildTools {
    param([string]$AndroidPlayer)
    $root = Join-Path $AndroidPlayer 'SDK\build-tools'
    $selected = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -match '^\d+\.\d+\.\d+$' } |
        Sort-Object { [version]$_.Name } -Descending |
        Select-Object -First 1
    if (!$selected) { throw "No Android build-tools found under $root" }
    return $selected.FullName
}

try {
    $apk = (Resolve-Path -LiteralPath $ApkPath).Path
    $editor = Find-EditorPath $EditorPath $apk
    $editorFolder = Split-Path $editor -Parent
    $androidPlayer = Join-Path $editorFolder 'Data\PlaybackEngines\AndroidPlayer'
    if (!(Test-Path -LiteralPath $androidPlayer)) {
        throw "AndroidPlayer not found: $androidPlayer"
    }

    $mapping = Get-AsciiMapping (Split-Path $editorFolder -Parent)
    $mappedAndroidPlayer = ConvertTo-MappedPath $androidPlayer $mapping
    $buildTools = Get-BuildTools $mappedAndroidPlayer
    $aapt2 = Join-Path $buildTools 'aapt2.exe'
    $apksigner = Join-Path $buildTools 'apksigner.bat'

    $badgingLines = & $aapt2 dump badging $apk 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($badgingLines -join "`n") }
    $badging = $badgingLines -join "`n"

    $packageMatch = [regex]::Match($badging, "package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'")
    if (!$packageMatch.Success) { throw "Could not parse aapt2 output:`n$badging" }
    $package = $packageMatch.Groups[1].Value
    $versionCode = $packageMatch.Groups[2].Value
    $versionName = $packageMatch.Groups[3].Value

    if ($ExpectedPackage -and $package -ne $ExpectedPackage) {
        throw "Package mismatch: expected '$ExpectedPackage', found '$package'."
    }
    if ($ExpectedVersion -and $versionName -ne $ExpectedVersion) {
        throw "Version mismatch: expected '$ExpectedVersion', found '$versionName'."
    }

    $minSdkMatch = [regex]::Match($badging, "(?m)^sdkVersion:'(\d+)'")
    $targetSdkMatch = [regex]::Match($badging, "(?m)^targetSdkVersion:'(\d+)'")
    $labelMatch = [regex]::Match($badging, "(?m)^application-label:'([^']*)'")
    $activityMatch = [regex]::Match($badging, "(?m)^launchable-activity: name='([^']+)'")
    $abis = @()
    $nativeMatch = [regex]::Match($badging, '(?m)^native-code:\s*(.+)$')
    if ($nativeMatch.Success) {
        $abis = [regex]::Matches($nativeMatch.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
    }
    if (!$activityMatch.Success) { throw 'The APK has no launcher activity.' }
    if ($abis.Count -eq 0) { throw 'The APK has no native-code ABI.' }

    $oldJavaHome = $env:JAVA_HOME
    $oldPath = $env:Path
    $env:JAVA_HOME = Join-Path $mappedAndroidPlayer 'OpenJDK'
    $env:Path = "$($env:JAVA_HOME)\bin;$oldPath"
    try {
        $signatureLines = & $apksigner verify --verbose --print-certs $apk 2>&1
        $signatureExit = $LASTEXITCODE
        $signature = $signatureLines -join "`n"
    }
    finally {
        $env:JAVA_HOME = $oldJavaHome
        $env:Path = $oldPath
    }
    if ($signatureExit -ne 0) { throw "Signature verification failed:`n$signature" }

    $summary = [ordered]@{
        apk = $apk
        sizeMB = [math]::Round((Get-Item -LiteralPath $apk).Length / 1MB, 2)
        sha256 = (Get-FileHash -LiteralPath $apk -Algorithm SHA256).Hash
        package = $package
        versionName = $versionName
        versionCode = $versionCode
        label = if ($labelMatch.Success) { $labelMatch.Groups[1].Value } else { $null }
        minSdk = if ($minSdkMatch.Success) { [int]$minSdkMatch.Groups[1].Value } else { $null }
        targetSdk = if ($targetSdkMatch.Success) { [int]$targetSdkMatch.Groups[1].Value } else { $null }
        abis = @($abis)
        launchActivity = $activityMatch.Groups[1].Value
        signedV1 = [bool]($signature -match 'Verified using v1 scheme \(JAR signing\): true')
        signedV2 = [bool]($signature -match 'Verified using v2 scheme \(APK Signature Scheme v2\): true')
        signedV3 = [bool]($signature -match 'Verified using v3 scheme \(APK Signature Scheme v3\): true')
        debugSigned = [bool]($signature -match 'CN=Android Debug')
    }

    Write-Output ($summary | ConvertTo-Json -Depth 6)
}
finally {
    foreach ($drive in $createdMappings) {
        & subst "${drive}:" /D 2>$null | Out-Null
    }
}
