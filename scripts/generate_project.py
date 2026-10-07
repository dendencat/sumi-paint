#!/usr/bin/env python3
"""Generate the checked-in Xcode project using only Python's standard library."""
from pathlib import Path
from hashlib import sha256
import json
import plistlib

ROOT = Path(__file__).resolve().parent.parent
PROJECT = ROOT / "SumiPaint.xcodeproj"


def identifier(key):
    return sha256(key.encode()).hexdigest()[:24].upper()


def quote(value):
    return json.dumps(str(value), ensure_ascii=False)


objects = {}


def add(key, isa, fields):
    uid = identifier(key)
    objects[uid] = f"isa = {isa}; {fields}"
    return uid


def array(items):
    return "(" + ", ".join(items) + ")"


def configuration_list(key, settings):
    configs = []
    for name in ("Debug", "Release"):
        config = dict(settings)
        config["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if name == "Debug" else "-O"
        config["DEBUG_INFORMATION_FORMAT"] = "dwarf" if name == "Debug" else "dwarf-with-dsym"
        if settings.get("CODE_SIGN_ENTITLEMENTS"):
            config["ENABLE_HARDENED_RUNTIME"] = "YES" if name == "Release" else "NO"
        config["ENABLE_TESTABILITY"] = "YES" if name == "Debug" else "NO"
        if name == "Debug":
            config["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        body = " ".join(f"{k} = {quote(v)};" for k, v in sorted(config.items()))
        configs.append(add(f"{key}/{name}", "XCBuildConfiguration", f"buildSettings = {{{body}}}; name = {name};"))
    return add(f"{key}/configs", "XCConfigurationList",
               f"buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")


source_paths = sorted([*ROOT.glob("App/*.swift"), *ROOT.glob("Sources/DrawingCore/*.swift"), *ROOT.glob("App/*.metal")])
references = {}
for path in source_paths:
    relative = path.relative_to(ROOT).as_posix()
    kind = "sourcecode.metal" if path.suffix == ".metal" else "sourcecode.swift"
    references[relative] = add(f"file/{relative}", "PBXFileReference",
        f"lastKnownFileType = {kind}; path = {quote(relative)}; sourceTree = SOURCE_ROOT;")

app_group = add("group/sources", "PBXGroup", f"children = {array(list(references.values()))}; name = Sources; sourceTree = \"<group>\";")
project_id = identifier("project")
products = []
targets = []
scheme_targets = {}
common = {
    "SWIFT_VERSION": "5.0", "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES",
    "CODE_SIGN_STYLE": "Automatic", "ENABLE_USER_SCRIPT_SANDBOXING": "YES",
    "CURRENT_PROJECT_VERSION": "1", "MARKETING_VERSION": "0.1.0",
    "SWIFT_EMIT_LOC_STRINGS": "YES", "PRODUCT_MODULE_NAME": "SumiPaint",
    "PRODUCT_NAME": "Sumi Paint", "GENERATE_INFOPLIST_FILE": "NO",
    "MTL_ENABLE_DEBUG_INFO": "INCLUDE_SOURCE", "MTL_FAST_MATH": "YES",
}

for platform in ("macOS", "iOS"):
    key = f"app/{platform}"
    product = add(f"{key}/product", "PBXFileReference",
        'explicitFileType = wrapper.application; includeInIndex = 0; path = "Sumi Paint.app"; sourceTree = BUILT_PRODUCTS_DIR;')
    products.append(product)
    build_files = [add(f"{key}/{path}", "PBXBuildFile", f"fileRef = {ref};") for path, ref in references.items()]
    sources = add(f"{key}/sources", "PBXSourcesBuildPhase", f"buildActionMask = 2147483647; files = {array(build_files)}; runOnlyForDeploymentPostprocessing = 0;")
    resources = add(f"{key}/resources", "PBXResourcesBuildPhase", "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    frameworks = add(f"{key}/frameworks", "PBXFrameworksBuildPhase", "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    settings = dict(common)
    settings["INFOPLIST_FILE"] = f"App/Info-{platform}.plist"
    if platform == "macOS":
        settings.update(SDKROOT="macosx", SUPPORTED_PLATFORMS="macosx", MACOSX_DEPLOYMENT_TARGET="14.0",
            PRODUCT_BUNDLE_IDENTIFIER="app.dendencat.sumipaint.mac", CODE_SIGN_ENTITLEMENTS="App/macOS.entitlements",
            LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/../Frameworks")
    else:
        settings.update(SDKROOT="iphoneos", SUPPORTED_PLATFORMS="iphoneos iphonesimulator", IPHONEOS_DEPLOYMENT_TARGET="17.0",
            TARGETED_DEVICE_FAMILY="1,2", SUPPORTS_MACCATALYST="NO", PRODUCT_BUNDLE_IDENTIFIER="app.dendencat.sumipaint",
            LD_RUNPATH_SEARCH_PATHS="$(inherited) @executable_path/Frameworks")
    configs = configuration_list(key, settings)
    target = add(key, "PBXNativeTarget", f"buildConfigurationList = {configs}; buildPhases = {array([sources, frameworks, resources])}; "
        f"buildRules = (); dependencies = (); name = {quote('SumiPaint-' + platform)}; productName = {quote('Sumi Paint')}; "
        f"productReference = {product}; productType = \"com.apple.product-type.application\";")
    targets.append(target)
    scheme_targets[platform] = target

test_path = "AppTests/PaintEngineTests.swift"
test_ref = add("file/tests", "PBXFileReference", f"lastKnownFileType = sourcecode.swift; path = {quote(test_path)}; sourceTree = SOURCE_ROOT;")
test_file = add("tests/buildfile", "PBXBuildFile", f"fileRef = {test_ref};")
test_product = add("tests/product", "PBXFileReference", 'explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = SumiPaintTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
products.append(test_product)
test_sources = add("tests/sources", "PBXSourcesBuildPhase", f"buildActionMask = 2147483647; files = ({test_file}); runOnlyForDeploymentPostprocessing = 0;")
test_frameworks = add("tests/frameworks", "PBXFrameworksBuildPhase", "buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
proxy = add("tests/proxy", "PBXContainerItemProxy", f"containerPortal = {project_id}; proxyType = 1; remoteGlobalIDString = {scheme_targets['macOS']}; remoteInfo = \"SumiPaint-macOS\";")
dependency = add("tests/dependency", "PBXTargetDependency", f"target = {scheme_targets['macOS']}; targetProxy = {proxy};")
test_configs = configuration_list("tests", {
    "SWIFT_VERSION": "5.0", "SDKROOT": "macosx", "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "PRODUCT_NAME": "SumiPaintTests", "PRODUCT_BUNDLE_IDENTIFIER": "app.dendencat.sumipaint.tests",
    "GENERATE_INFOPLIST_FILE": "YES", "CODE_SIGN_STYLE": "Automatic",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/Sumi Paint.app/Contents/MacOS/Sumi Paint",
    "BUNDLE_LOADER": "$(TEST_HOST)", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks @loader_path/../Frameworks",
})
test_target = add("tests", "PBXNativeTarget", f"buildConfigurationList = {test_configs}; buildPhases = {array([test_sources, test_frameworks])}; "
    f"buildRules = (); dependencies = ({dependency}); name = SumiPaintTests; productName = SumiPaintTests; "
    f"productReference = {test_product}; productType = \"com.apple.product-type.bundle.unit-test\";")
targets.append(test_target)
test_group = add("group/tests", "PBXGroup", f"children = ({test_ref}); name = Tests; sourceTree = \"<group>\";")
product_group = add("group/products", "PBXGroup", f"children = {array(products)}; name = Products; sourceTree = \"<group>\";")
main_group = add("group/main", "PBXGroup", f"children = {array([app_group, test_group, product_group])}; sourceTree = \"<group>\";")
project_configs = configuration_list("project", {"ALWAYS_SEARCH_USER_PATHS": "NO", "CLANG_ANALYZER_NONNULL": "YES", "GCC_WARN_64_TO_32_BIT_CONVERSION": "YES"})
add("project", "PBXProject", f"attributes = {{LastUpgradeCheck = 1600; LastSwiftUpdateCheck = 1600;}}; "
    f"buildConfigurationList = {project_configs}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = ja; "
    f"hasScannedForEncodings = 0; knownRegions = (ja, en, Base); mainGroup = {main_group}; productRefGroup = {product_group}; "
    f"projectDirPath = \"\"; projectRoot = \"\"; targets = {array(targets)};")
PROJECT.mkdir(exist_ok=True)
body = "\n".join(f"\t\t{uid} = {{{value}}};" for uid, value in sorted(objects.items()))
(PROJECT / "project.pbxproj").write_text(f"// !$*UTF8*$!\n{{\n\tarchiveVersion = 1; classes = {{}}; objectVersion = 56;\n\tobjects = {{\n{body}\n\t}};\n\trootObject = {project_id};\n}}\n")

schemes = PROJECT / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
for platform, target in scheme_targets.items():
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Sumi Paint.app" BlueprintName="SumiPaint-{platform}" ReferencedContainer="container:SumiPaint.xcodeproj"/>'
    test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="SumiPaintTests.xctest" BlueprintName="SumiPaintTests" ReferencedContainer="container:SumiPaint.xcodeproj"/>'
    testable = f'<TestableReference skipped="NO">{test_reference}</TestableReference>' if platform == "macOS" else ""
    xml = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{testable}</Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes / f"SumiPaint-{platform}.xcscheme").write_text(xml)

for platform in ("macOS", "iOS"):
    info = {
        "CFBundleDevelopmentRegion": "ja", "CFBundleDisplayName": "Sumi Paint", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": "Sumi Paint", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "UTExportedTypeDeclarations": [{"UTTypeIdentifier": "app.dendencat.sumipaint.document", "UTTypeDescription": "Sumi Paint作品",
            "UTTypeConformsTo": ["public.data"], "UTTypeTagSpecification": {"public.filename-extension": ["sumipaint"]}}],
    }
    if platform == "iOS":
        info.update(LSRequiresIPhoneOS=True, UILaunchScreen={},
            UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False, "UISceneConfigurations": {}},
            UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
            **{"UISupportedInterfaceOrientations~ipad": ["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"]})
    else:
        info.update(LSMinimumSystemVersion="$(MACOSX_DEPLOYMENT_TARGET)", LSApplicationCategoryType="public.app-category.graphics-design")
    with (ROOT / f"App/Info-{platform}.plist").open("wb") as file:
        plistlib.dump(info, file, sort_keys=True)
print("Generated SumiPaint.xcodeproj (macOS, iPhone, iPad).")
