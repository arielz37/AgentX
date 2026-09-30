#!/usr/bin/env python3
"""Generate the independent no-dependency Xcode project; no legacy project edits."""
from pathlib import Path
import hashlib
ROOT=Path(__file__).resolve().parents[1]
def ident(s):return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def q(s):return '"'+s+'"'
objects={}
def add(key,text):objects[ident(key)]=text;return ident(key)
sources=sorted(str(p.relative_to(ROOT)) for p in (ROOT/'AgentX').rglob('*.swift'))
resources=['AgentX/Assets.xcassets','AgentXConfig.plist']
refs=[];srcbuild=[];resbuild=[]
for p in sources+resources:
 typ='sourcecode.swift' if p.endswith('.swift') else 'folder.assetcatalog' if p.endswith('.xcassets') else 'text.plist.xml'
 r=add('ref'+p,f'{{isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(p)}; sourceTree = SOURCE_ROOT; }}');refs.append(r)
 b=add('build'+p,f'{{isa = PBXBuildFile; fileRef = {r}; }}')
 (srcbuild if p in sources else resbuild).append(b)
config=add('configfile','{isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Config.xcconfig; sourceTree = SOURCE_ROOT; }');refs.append(config)
product=add('product','{isa = PBXFileReference; explicitFileType = wrapper.application; path = AgentX.app; sourceTree = BUILT_PRODUCTS_DIR; }')
def array(xs):return '('+', '.join(xs)+',)' if xs else '()'
products=add('products',f'{{isa = PBXGroup; name = Products; children = {array([product])}; sourceTree = "<group>"; }}')
group=add('main',f'{{isa = PBXGroup; children = {array(refs+[products])}; sourceTree = "<group>"; }}')
sourcephase=add('sources',f'{{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {array(srcbuild)}; runOnlyForDeploymentPostprocessing = 0; }}')
resourcephase=add('resources',f'{{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {array(resbuild)}; runOnlyForDeploymentPostprocessing = 0; }}')
frameworks=add('frameworks','{isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; }')
for scope in ['project','target']:
 configs=[]
 for mode in ['Debug','Release']:
  settings='CLANG_ENABLE_MODULES = YES; SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SWIFT_VERSION = 5.0;'
  if scope=='target':settings+=' PRODUCT_NAME = AgentX; INFOPLIST_FILE = AgentX/Info.plist; CODE_SIGN_STYLE = Automatic; TARGETED_DEVICE_FAMILY = 1; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ENABLE_PREVIEWS = YES;'
  if mode=='Debug':settings+=' SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf;'
  else:settings+=' SWIFT_OPTIMIZATION_LEVEL = "-O";'
  configs.append(add(scope+mode,f'{{isa = XCBuildConfiguration; '+(f'baseConfigurationReference = {config}; ' if scope=='target' else '')+f'buildSettings = {{{settings}}}; name = {mode}; }}'))
 add(scope+'configs',f'{{isa = XCConfigurationList; buildConfigurations = {array(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; }}')
target=add('target',f'{{isa = PBXNativeTarget; buildConfigurationList = {ident("targetconfigs")}; buildPhases = {array([sourcephase,frameworks,resourcephase])}; buildRules = (); dependencies = (); name = AgentX; productName = AgentX; productReference = {product}; productType = "com.apple.product-type.application"; }}')
project=add('project',f'{{isa = PBXProject; attributes = {{LastUpgradeCheck = 2620; }}; buildConfigurationList = {ident("projectconfigs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = {array([target])}; }}')
p=ROOT/'AgentX.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(f'{k} = {v};\n' for k,v in objects.items())+f'}}; rootObject = {project}; }}\n')
s=p/'xcshareddata/xcschemes';s.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AgentX.app" BlueprintName="AgentX" ReferencedContainer="container:AgentX.xcodeproj"/>'
(s/'AgentX.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2620" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug"/><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
