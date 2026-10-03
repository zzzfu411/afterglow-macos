#!/usr/bin/env python3
"""Generate a dependency-free Xcode project. IDs are stable for reviewable diffs."""
from pathlib import Path
import hashlib
import plistlib

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Afterglow.xcodeproj'
PROJECT.mkdir(exist_ok=True)

def uid(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def q(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'

objects = []
def obj(name, isa, fields):
    objects.append(f'\t\t{uid(name)} = {{isa = {isa}; {fields} }};')
    return uid(name)

def refs(names):
    return '(' + ', '.join(uid(name) for name in names) + ', )'

shared = ['Shared/FocusState.swift', 'Shared/FocusStore.swift', 'Shared/FocusViews.swift']
app = ['App/AfterglowApp.swift', 'App/FocusWindow.swift', 'App/FocusSettings.swift', 'App/FocusLayout.swift', 'App/NativeMaterial.swift',
       'App/FocusModel.swift', 'App/FocusReminders.swift', 'App/FocusStoreObservation.swift']
intent = ['Widget/TimerIntents.swift']
widget = ['Widget/AfterglowWidget.swift']
metadata = ['App/Info.plist', 'Widget/Info.plist', 'Config/App.entitlements', 'Config/Widget.entitlements', 'Config/Signing.xcconfig', 'Preview/AppIcon.icns']

for path in shared + app + intent + widget + metadata:
    ext = Path(path).suffix
    kind = {'.swift': 'sourcecode.swift', '.plist': 'text.plist.xml', '.entitlements': 'text.plist.entitlements', '.xcconfig': 'text.xcconfig', '.icns': 'image.icns'}[ext]
    obj(path, 'PBXFileReference', f'lastKnownFileType = {kind}; path = {q(path)}; sourceTree = SOURCE_ROOT;')

for name, extension, filetype in [('Afterglow', 'app', 'wrapper.application'), ('AfterglowWidgets', 'appex', 'wrapper.app-extension')]:
    obj(name + '-product', 'PBXFileReference', f'explicitFileType = {filetype}; includeInIndex = 0; path = {name}.{extension}; sourceTree = BUILT_PRODUCTS_DIR;')

obj('sources-group', 'PBXGroup', f'name = Sources; children = {refs(shared + app + intent + widget)}; sourceTree = "<group>";')
obj('config-group', 'PBXGroup', f'name = Configuration; children = {refs(metadata)}; sourceTree = "<group>";')
obj('products-group', 'PBXGroup', f'name = Products; children = {refs(["Afterglow-product", "AfterglowWidgets-product"])}; sourceTree = "<group>";')
obj('root-group', 'PBXGroup', f'children = {refs(["sources-group", "config-group", "products-group"])}; sourceTree = "<group>";')

for target, sources in [('Afterglow', shared + app + intent), ('AfterglowWidgets', shared + intent + widget)]:
    names = []
    for path in sources:
        name = target + '-' + path
        obj(name, 'PBXBuildFile', f'fileRef = {uid(path)};')
        names.append(name)
    obj(target + '-sources', 'PBXSourcesBuildPhase', f'buildActionMask = 2147483647; files = {refs(names)}; runOnlyForDeploymentPostprocessing = 0;')
    obj(target + '-frameworks', 'PBXFrameworksBuildPhase', 'buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    resources = []
    if target == 'Afterglow':
        obj('app-icon-resource', 'PBXBuildFile', f'fileRef = {uid("Preview/AppIcon.icns")};')
        resources.append('app-icon-resource')
    obj(target + '-resources', 'PBXResourcesBuildPhase', f'buildActionMask = 2147483647; files = {refs(resources) if resources else "()"}; runOnlyForDeploymentPostprocessing = 0;')

obj('embed-widget', 'PBXBuildFile', f'fileRef = {uid("AfterglowWidgets-product")}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }};')
obj('embed-phase', 'PBXCopyFilesBuildPhase', f'buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = {refs(["embed-widget"])}; name = "Embed App Extensions"; runOnlyForDeploymentPostprocessing = 0;')
obj('widget-proxy', 'PBXContainerItemProxy', f'containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("AfterglowWidgets-target")}; remoteInfo = AfterglowWidgets;')
obj('widget-dependency', 'PBXTargetDependency', f'target = {uid("AfterglowWidgets-target")}; targetProxy = {uid("widget-proxy")};')

project_settings = {
    'CLANG_ENABLE_MODULES': 'YES', 'CLANG_ENABLE_OBJC_ARC': 'YES',
    'MACOSX_DEPLOYMENT_TARGET': '14.0', 'SDKROOT': 'macosx',
    'SWIFT_VERSION': '5.0', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES',
    'CODE_SIGN_STYLE': 'Automatic', 'COMBINE_HIDPI_IMAGES': 'YES',
}
def settings_text(settings):
    return '{' + ' '.join(f'{key} = {q(value)};' for key, value in settings.items()) + '}'

for target in ['project', 'Afterglow', 'AfterglowWidgets']:
    for config in ['Debug', 'Release']:
        settings = dict(project_settings) if target == 'project' else {}
        if target == 'project':
            settings.update({'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O',
                             'DEBUG_INFORMATION_FORMAT': 'dwarf' if config == 'Debug' else 'dwarf-with-dsym'})
        else:
            is_widget = target == 'AfterglowWidgets'
            settings.update({
                'PRODUCT_NAME': target, 'PRODUCT_BUNDLE_IDENTIFIER': 'app.afterglow.mac.widgets' if is_widget else 'app.afterglow.mac',
                'INFOPLIST_FILE': 'Widget/Info.plist' if is_widget else 'App/Info.plist',
                'CODE_SIGN_ENTITLEMENTS': 'Config/Widget.entitlements' if is_widget else 'Config/App.entitlements',
                'GENERATE_INFOPLIST_FILE': 'NO', 'ENABLE_APP_SANDBOX': 'YES', 'ENABLE_HARDENED_RUNTIME': 'YES',
                'CURRENT_PROJECT_VERSION': '6', 'MARKETING_VERSION': '0.3.2',
                'SWIFT_ACTIVE_COMPILATION_CONDITIONS': 'AFTERGLOW_WIDGET' if is_widget else '',
                'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks' if is_widget else '$(inherited) @executable_path/../Frameworks',
                'SKIP_INSTALL': 'YES' if is_widget else 'NO',
                'APPLICATION_EXTENSION_API_ONLY': 'YES' if is_widget else 'NO',
                'SWIFT_EMIT_LOC_STRINGS': 'YES',
            })
        obj(f'{target}-{config}', 'XCBuildConfiguration', f'baseConfigurationReference = {uid("Config/Signing.xcconfig")}; buildSettings = {settings_text(settings)}; name = {config};')
    obj(target + '-config-list', 'XCConfigurationList', f'buildConfigurations = {refs([target + "-Debug", target + "-Release"])}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

for target in ['Afterglow', 'AfterglowWidgets']:
    phases = [target + '-sources', target + '-frameworks', target + '-resources']
    if target == 'Afterglow': phases.append('embed-phase')
    deps = refs(['widget-dependency']) if target == 'Afterglow' else '()'
    typ = 'com.apple.product-type.application' if target == 'Afterglow' else 'com.apple.product-type.app-extension'
    obj(target + '-target', 'PBXNativeTarget', f'buildConfigurationList = {uid(target + "-config-list")}; buildPhases = {refs(phases)}; buildRules = (); dependencies = {deps}; name = {target}; productName = {target}; productReference = {uid(target + "-product")}; productType = {q(typ)};')

attrs = ' '.join(f'{uid(t + "-target")} = {{CreatedOnToolsVersion = 16.0; ProvisioningStyle = Automatic; SystemCapabilities = {{com.apple.ApplicationGroups.Mac = {{enabled = 1; }}; com.apple.Sandbox = {{enabled = 1; }}; }}; }};' for t in ['Afterglow', 'AfterglowWidgets'])
obj('project', 'PBXProject', f'attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 1600; TargetAttributes = {{{attrs}}}; }}; buildConfigurationList = {uid("project-config-list")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; hasScannedForEncodings = 0; knownRegions = ("zh-Hans", en, Base, ); mainGroup = {uid("root-group")}; productRefGroup = {uid("products-group")}; projectDirPath = ""; projectRoot = ""; targets = {refs(["Afterglow-target", "AfterglowWidgets-target"])};')

(PROJECT / 'project.pbxproj').write_text('// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n' + '\n'.join(objects) + f'\n\t}};\n\trootObject = {uid("project")};\n}}\n')
scheme_dir = PROJECT / 'xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("Afterglow-target")}" BuildableName="Afterglow.app" BlueprintName="Afterglow" ReferencedContainer="container:Afterglow.xcodeproj"/>'
(scheme_dir / 'Afterglow.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(PROJECT)
