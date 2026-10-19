using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

public static class CodexAndroidBuild
{
    private const string DefaultScenePath = "Assets/Scenes/Main.unity";
    private const string DefaultIconPath = "Assets/Art/AppIcon.png";

    [MenuItem("Tools/Codex/Build Android APK")]
    public static void BuildApk()
    {
        try
        {
            Build();
        }
        catch (Exception exception)
        {
            Debug.LogError("CODEX_ANDROID_BUILD_FAILED|" + exception);
            throw;
        }
    }

    private static void Build()
    {
        if (EditorUserBuildSettings.activeBuildTarget != BuildTarget.Android)
        {
            if (!EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android))
                throw new Exception("Unable to switch the active build target to Android.");
        }

        ConfigureAndroid();

        string outputDirectory = GetEnvironment("CODEX_ANDROID_OUTPUT_DIR", string.Empty);
        if (string.IsNullOrWhiteSpace(outputDirectory))
            throw new Exception("CODEX_ANDROID_OUTPUT_DIR is not set.");

        Directory.CreateDirectory(outputDirectory);

        bool buildAppBundle = GetEnvironment("CODEX_ANDROID_BUILD_AAB", "0") == "1";
        string extension = buildAppBundle ? ".aab" : ".apk";
        string fileName = GetEnvironment("CODEX_ANDROID_APK_NAME", PlayerSettings.productName + extension);
        if (!fileName.EndsWith(extension, StringComparison.OrdinalIgnoreCase))
            fileName += extension;

        string outputPath = Path.Combine(outputDirectory, fileName);
        if (File.Exists(outputPath))
            File.Delete(outputPath);

        BuildPlayerOptions options = new BuildPlayerOptions
        {
            scenes = GetScenes(),
            locationPathName = outputPath,
            target = BuildTarget.Android,
            options = BuildOptions.None
        };

        BuildReport report = BuildPipeline.BuildPlayer(options);
        if (report.summary.result != BuildResult.Succeeded)
            throw new Exception("Android build failed: " + report.summary.result);

        Debug.Log("CODEX_ANDROID_BUILD_SUCCESS|" + outputPath + "|" + report.summary.totalSize);
    }

    private static void ConfigureAndroid()
    {
        string productName = GetEnvironment("CODEX_ANDROID_PRODUCT_NAME", PlayerSettings.productName).Trim();
        string bundleId = GetEnvironment(
            "CODEX_ANDROID_BUNDLE_ID",
            PlayerSettings.GetApplicationIdentifier(BuildTargetGroup.Android)).Trim();

        if (string.IsNullOrWhiteSpace(bundleId))
            bundleId = "com.example.game";

        PlayerSettings.companyName = GetEnvironment("CODEX_ANDROID_COMPANY_NAME", PlayerSettings.companyName).Trim();
        PlayerSettings.productName = productName;
        PlayerSettings.bundleVersion = GetEnvironment("CODEX_ANDROID_VERSION_NAME", PlayerSettings.bundleVersion).Trim();
        PlayerSettings.Android.bundleVersionCode = ParseInt(
            "CODEX_ANDROID_VERSION_CODE",
            PlayerSettings.Android.bundleVersionCode);
        PlayerSettings.SetApplicationIdentifier(BuildTargetGroup.Android, bundleId);

        ConfigureOrientation(GetEnvironment("CODEX_ANDROID_ORIENTATION", "landscape").Trim());

        PlayerSettings.Android.targetArchitectures = ParseArchitectures(
            GetEnvironment("CODEX_ANDROID_ARCHS", "armv7,arm64"));
        PlayerSettings.Android.minSdkVersion = (AndroidSdkVersions)ParseInt("CODEX_ANDROID_MIN_SDK", 22);
        PlayerSettings.Android.targetSdkVersion = AndroidSdkVersions.AndroidApiLevelAuto;
        PlayerSettings.Android.forceInternetPermission = false;
        PlayerSettings.Android.renderOutsideSafeArea = false;

        ConfigureKeystore();

        string backend = GetEnvironment("CODEX_ANDROID_SCRIPTING_BACKEND", "il2cpp").Trim().ToLowerInvariant();
        if (backend == "mono")
        {
            PlayerSettings.SetScriptingBackend(BuildTargetGroup.Android, ScriptingImplementation.Mono2x);
        }
        else
        {
            PlayerSettings.SetScriptingBackend(BuildTargetGroup.Android, ScriptingImplementation.IL2CPP);
            PlayerSettings.SetIl2CppCompilerConfiguration(
                BuildTargetGroup.Android,
                Il2CppCompilerConfiguration.Release);
        }

        PlayerSettings.SetApiCompatibilityLevel(
            BuildTargetGroup.Android,
            ApiCompatibilityLevel.NET_Standard_2_0);
        PlayerSettings.SetManagedStrippingLevel(BuildTargetGroup.Android, ManagedStrippingLevel.Low);

        EditorUserBuildSettings.buildAppBundle = GetEnvironment("CODEX_ANDROID_BUILD_AAB", "0") == "1";
        EditorUserBuildSettings.androidBuildType = AndroidBuildType.Release;
        EditorUserBuildSettings.androidBuildSystem = AndroidBuildSystem.Gradle;

        ConfigureIcon();
        AssetDatabase.SaveAssets();
    }

    private static void ConfigureOrientation(string orientation)
    {
        switch (orientation.ToLowerInvariant())
        {
            case "portrait":
                PlayerSettings.defaultInterfaceOrientation = UIOrientation.Portrait;
                PlayerSettings.allowedAutorotateToPortrait = true;
                PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;
                PlayerSettings.allowedAutorotateToLandscapeLeft = false;
                PlayerSettings.allowedAutorotateToLandscapeRight = false;
                break;

            case "auto":
                PlayerSettings.defaultInterfaceOrientation = UIOrientation.AutoRotation;
                PlayerSettings.allowedAutorotateToPortrait = true;
                PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;
                PlayerSettings.allowedAutorotateToLandscapeLeft = true;
                PlayerSettings.allowedAutorotateToLandscapeRight = true;
                break;

            default:
                PlayerSettings.defaultInterfaceOrientation = UIOrientation.LandscapeLeft;
                PlayerSettings.allowedAutorotateToPortrait = false;
                PlayerSettings.allowedAutorotateToPortraitUpsideDown = false;
                PlayerSettings.allowedAutorotateToLandscapeLeft = true;
                PlayerSettings.allowedAutorotateToLandscapeRight = true;
                break;
        }
    }

    private static void ConfigureKeystore()
    {
        string keystore = GetEnvironment("CODEX_ANDROID_KEYSTORE", string.Empty);
        if (string.IsNullOrWhiteSpace(keystore))
        {
            PlayerSettings.Android.useCustomKeystore = false;
            return;
        }

        PlayerSettings.Android.useCustomKeystore = true;
        PlayerSettings.Android.keystoreName = keystore;
        PlayerSettings.Android.keystorePass = GetEnvironment("CODEX_ANDROID_KEYSTORE_PASSWORD", string.Empty);
        PlayerSettings.Android.keyaliasName = GetEnvironment("CODEX_ANDROID_KEYSTORE_ALIAS", string.Empty);
        PlayerSettings.Android.keyaliasPass = GetEnvironment("CODEX_ANDROID_KEY_PASSWORD", string.Empty);
    }

    private static void ConfigureIcon()
    {
        string iconPath = GetEnvironment("CODEX_ANDROID_ICON", DefaultIconPath);
        if (!File.Exists(iconPath))
        {
            Debug.LogWarning("Android icon not found at " + iconPath);
            return;
        }

        TextureImporter importer = AssetImporter.GetAtPath(iconPath) as TextureImporter;
        if (importer == null)
        {
            AssetDatabase.ImportAsset(iconPath, ImportAssetOptions.ForceUpdate);
            importer = AssetImporter.GetAtPath(iconPath) as TextureImporter;
        }

        if (importer != null)
        {
            importer.textureType = TextureImporterType.Default;
            importer.mipmapEnabled = false;
            importer.alphaIsTransparency = true;
            importer.maxTextureSize = 512;
            importer.SaveAndReimport();
        }

        Texture2D icon = AssetDatabase.LoadAssetAtPath<Texture2D>(iconPath);
        if (icon != null)
            PlayerSettings.SetIconsForTargetGroup(BuildTargetGroup.Android, new[] { icon });
    }

    private static string[] GetScenes()
    {
        string sceneOverride = GetEnvironment("CODEX_ANDROID_SCENES", string.Empty);
        string[] scenes;

        if (!string.IsNullOrWhiteSpace(sceneOverride))
        {
            scenes = sceneOverride
                .Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(path => path.Trim())
                .Where(path => path.Length > 0)
                .ToArray();
        }
        else
        {
            scenes = EditorBuildSettings.scenes
                .Where(scene => scene.enabled)
                .Select(scene => scene.path)
                .ToArray();
        }

        if (scenes.Length == 0 && File.Exists(DefaultScenePath))
            scenes = new[] { DefaultScenePath };

        if (scenes.Length == 0)
            throw new Exception("No scenes configured for the Android build.");

        foreach (string scene in scenes)
        {
            if (!File.Exists(scene))
                throw new Exception("Scene not found: " + scene);
        }

        return scenes;
    }

    private static AndroidArchitecture ParseArchitectures(string value)
    {
        AndroidArchitecture architectures = 0;
        foreach (string part in value.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
        {
            switch (part.Trim().ToLowerInvariant())
            {
                case "armv7":
                case "armeabi-v7a":
                    architectures |= AndroidArchitecture.ARMv7;
                    break;
                case "arm64":
                case "arm64-v8a":
                    architectures |= AndroidArchitecture.ARM64;
                    break;
                case "x86":
                    architectures |= AndroidArchitecture.X86;
                    break;
                case "x86_64":
                case "x86-64":
                    architectures |= AndroidArchitecture.X86_64;
                    break;
            }
        }

        if (architectures == 0)
            architectures = AndroidArchitecture.ARMv7 | AndroidArchitecture.ARM64;

        return architectures;
    }

    private static int ParseInt(string name, int fallback)
    {
        int value;
        return int.TryParse(GetEnvironment(name, string.Empty), out value) ? value : fallback;
    }

    private static string GetEnvironment(string name, string fallback)
    {
        string value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }
}
