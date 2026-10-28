#!/usr/bin/env python3
"""Generate a deterministic, dependency-free Xcode project."""
from pathlib import Path
import hashlib
import json
import plistlib

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def add(name, value):
    key = ident(name); objects[key] = value; return key
def ref(path, kind="sourcecode.swift", tree="SOURCE_ROOT"):
    return add("file:" + path, {"isa":"PBXFileReference", "lastKnownFileType":kind, "path":path, "sourceTree":tree})
def build(file_id, key, settings=None):
    value={"isa":"PBXBuildFile", "fileRef":file_id}
    if settings: value["settings"] = settings
    return add("build:"+key,value)
def phase(name, isa, files): return add(name,{"isa":isa,"buildActionMask":2147483647,"files":files,"runOnlyForDeploymentPostprocessing":0})
def group(name, children): return add("group:"+name,{"isa":"PBXGroup","name":name,"children":children,"sourceTree":"<group>"})
local = ref("Local.xcconfig","text.xcconfig") if (ROOT/"Local.xcconfig").exists() else None
def configs(name, settings):
    ids=[]
    for mode in ["Debug","Release"]:
        values=dict(settings)
        values.update({"SWIFT_OPTIMIZATION_LEVEL":"-Onone" if mode=="Debug" else "-O", "DEBUG_INFORMATION_FORMAT":"dwarf" if mode=="Debug" else "dwarf-with-dsym"})
        values["ONLY_ACTIVE_ARCH"] = "YES" if mode=="Debug" else "NO"
        if mode=="Debug": values["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]="DEBUG $(inherited)"
        obj={"isa":"XCBuildConfiguration","name":mode,"buildSettings":values}
        if local:obj["baseConfigurationReference"]=local
        ids.append(add("config:"+name+mode,obj))
    return add("configs:"+name,{"isa":"XCConfigurationList","buildConfigurations":ids,"defaultConfigurationIsVisible":0,"defaultConfigurationName":"Release"})

app_files=[ref(str(x.relative_to(ROOT))) for x in sorted((ROOT/"ClashDashApp").rglob("*.swift"))]
tunnel_files=[ref(str(x.relative_to(ROOT))) for folder in ["ClashDashTunnel","Vendor/ClashAdapter"] for x in sorted((ROOT/folder).rglob("*.swift"))]
test_files=[ref(str(x.relative_to(ROOT))) for x in sorted((ROOT/"UITests").rglob("*.swift"))] if (ROOT/"UITests").exists() else []
core=ref("Vendor/Clash.xcframework","wrapper.xcframework")
resolv=ref("usr/lib/libresolv.tbd","sourcecode.text-based-dylib-definition","SDKROOT")
assets=ref("ClashDashApp/Assets.xcassets","folder.assetcatalog")
license_ref=ref("Vendor/Licenses/GPL-3.0.txt","text")
fixture_ref=ref("Fixtures/direct-diagnostic.yaml","text.yaml")
notice_refs=[ref("Vendor/NOTICE","text"),ref("Vendor/THIRD_PARTY_LICENSES.md","text"),ref("Vendor/THIRD_PARTY_LICENSES","folder"),ref("Vendor/Licenses/Yams-MIT.txt","text")]
app_product=add("product:app",{"isa":"PBXFileReference","explicitFileType":"wrapper.application","path":"DashInto.app","sourceTree":"BUILT_PRODUCTS_DIR"})
ext_product=add("product:extension",{"isa":"PBXFileReference","explicitFileType":"wrapper.app-extension","path":"ClashDashTunnel.appex","sourceTree":"BUILT_PRODUCTS_DIR"})
test_product=add("product:uitests",{"isa":"PBXFileReference","explicitFileType":"wrapper.cfbundle","path":"ClashDashUITests.xctest","sourceTree":"BUILT_PRODUCTS_DIR"})
package=add("package:kit",{"isa":"XCLocalSwiftPackageReference","relativePath":"Packages/ClashDashKit"})
def package_product(target): return add("packageProduct:"+target,{"isa":"XCSwiftPackageProductDependency","package":package,"productName":"ClashDashKit"})
app_kit=package_product("app"); ext_kit=package_product("extension")
def package_build(key, product): return add("packageBuild:"+key,{"isa":"PBXBuildFile","productRef":product})
project_id=ident("project");app_id=ident("target:app");ext_id=ident("target:extension");test_id=ident("target:uitests")
def dependency(key,target):
    proxy=add("proxy:"+key,{"isa":"PBXContainerItemProxy","containerPortal":project_id,"proxyType":1,"remoteGlobalIDString":target,"remoteInfo":key})
    return add("dependency:"+key,{"isa":"PBXTargetDependency","target":target,"targetProxy":proxy})
app_sources=phase("app:sources","PBXSourcesBuildPhase",[build(x,"app"+x) for x in app_files])
ext_sources=phase("ext:sources","PBXSourcesBuildPhase",[build(x,"ext"+x) for x in tunnel_files])
app_frameworks=phase("app:frameworks","PBXFrameworksBuildPhase",[package_build("app",app_kit),build(core,"appcore"),build(resolv,"appresolv")])
ext_frameworks=phase("ext:frameworks","PBXFrameworksBuildPhase",[package_build("extension",ext_kit),build(core,"core"),build(resolv,"resolv")])
app_resources=phase("app:resources","PBXResourcesBuildPhase",[build(assets,"assets"),build(license_ref,"license"),build(fixture_ref,"fixture")]+[build(x,"notice"+x) for x in notice_refs])
ext_resources=phase("ext:resources","PBXResourcesBuildPhase",[])
embed=add("app:embed",{"isa":"PBXCopyFilesBuildPhase","buildActionMask":2147483647,"dstPath":"","dstSubfolderSpec":13,"files":[build(ext_product,"embed",{"ATTRIBUTES":["RemoveHeadersOnCopy"]})],"name":"Embed App Extensions","runOnlyForDeploymentPostprocessing":0})
common={"SDKROOT":"iphoneos","SUPPORTED_PLATFORMS":"iphoneos iphonesimulator","IPHONEOS_DEPLOYMENT_TARGET":"18.0","SWIFT_VERSION":"5.0","SWIFT_STRICT_CONCURRENCY":"targeted","TARGETED_DEVICE_FAMILY":"1,2","CODE_SIGN_STYLE":"Automatic","CLANG_ENABLE_MODULES":"YES","ENABLE_USER_SCRIPT_SANDBOXING":"YES","APP_BUNDLE_ID":"app.clashdash.ios","APP_GROUP_ID":"group.app.clashdash.ios","CURRENT_PROJECT_VERSION":"8","MARKETING_VERSION":"0.4.4","SWIFT_EMIT_LOC_STRINGS":"YES"}
app_config={"PRODUCT_NAME":"DashInto","PRODUCT_BUNDLE_IDENTIFIER":"$(APP_BUNDLE_ID)","INFOPLIST_FILE":"ClashDashApp/Info.plist","CODE_SIGN_ENTITLEMENTS":"ClashDashApp/ClashDash.entitlements","ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon","ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME":"AccentColor","LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks","ENABLE_PREVIEWS":"YES"}
ext_config={"PRODUCT_NAME":"ClashDashTunnel","PRODUCT_BUNDLE_IDENTIFIER":"$(APP_BUNDLE_ID).tunnel","INFOPLIST_FILE":"ClashDashTunnel/Info.plist","CODE_SIGN_ENTITLEMENTS":"ClashDashTunnel/ClashDashTunnel.entitlements","APPLICATION_EXTENSION_API_ONLY":"YES","SKIP_INSTALL":"YES","LD_RUNPATH_SEARCH_PATHS":"$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks","OTHER_LDFLAGS":"$(inherited) -lresolv","SWIFT_OBJC_BRIDGING_HEADER":"","ENABLE_BITCODE":"NO"}
add("target:app",{"isa":"PBXNativeTarget","buildConfigurationList":configs("app",app_config),"buildPhases":[app_sources,app_frameworks,app_resources,embed],"buildRules":[],"dependencies":[dependency("ClashDashTunnel",ext_id)],"name":"ClashDash","productName":"DashInto","productReference":app_product,"productType":"com.apple.product-type.application","packageProductDependencies":[app_kit]})
add("target:extension",{"isa":"PBXNativeTarget","buildConfigurationList":configs("extension",ext_config),"buildPhases":[ext_sources,ext_frameworks,ext_resources],"buildRules":[],"dependencies":[],"name":"ClashDashTunnel","productName":"ClashDashTunnel","productReference":ext_product,"productType":"com.apple.product-type.app-extension","packageProductDependencies":[ext_kit]})
test_sources=phase("test:sources","PBXSourcesBuildPhase",[build(x,"test"+x) for x in test_files])
test_config={"PRODUCT_NAME":"ClashDashUITests","PRODUCT_BUNDLE_IDENTIFIER":"$(APP_BUNDLE_ID).uitests","GENERATE_INFOPLIST_FILE":"YES","TEST_TARGET_NAME":"ClashDash","CODE_SIGNING_ALLOWED":"YES"}
add("target:uitests",{"isa":"PBXNativeTarget","buildConfigurationList":configs("test",test_config),"buildPhases":[test_sources,phase("test:frameworks","PBXFrameworksBuildPhase",[])],"buildRules":[],"dependencies":[dependency("ClashDash",app_id)],"name":"ClashDashUITests","productName":"ClashDashUITests","productReference":test_product,"productType":"com.apple.product-type.bundle.ui-testing"})
children=[group("ClashDashApp",app_files+[assets,ref("ClashDashApp/Info.plist","text.plist.xml"),ref("ClashDashApp/ClashDash.entitlements","text.plist.entitlements")]),group("ClashDashTunnel",tunnel_files+[ref("ClashDashTunnel/Info.plist","text.plist.xml"),ref("ClashDashTunnel/ClashDashTunnel.entitlements","text.plist.entitlements")]),group("Dependencies",[core,resolv,license_ref,fixture_ref]+notice_refs),group("UITests",test_files),group("Products",[app_product,ext_product,test_product])]
if local:children.append(local)
main=group("ClashDash",children)
add("project",{"isa":"PBXProject","attributes":{"BuildIndependentTargetsInParallel":"YES","LastUpgradeCheck":"2660","TargetAttributes":{app_id:{"CreatedOnToolsVersion":"26.6"},ext_id:{"CreatedOnToolsVersion":"26.6"},test_id:{"CreatedOnToolsVersion":"26.6","TestTargetID":app_id}}},"buildConfigurationList":configs("project",common),"compatibilityVersion":"Xcode 15.0","developmentRegion":"zh-Hans","hasScannedForEncodings":0,"knownRegions":["zh-Hans","en","Base"],"mainGroup":main,"productRefGroup":ident("group:Products"),"projectDirPath":"","projectRoot":"","targets":[app_id,ext_id,test_id],"packageReferences":[package]})

def encode(value, level=0):
    if isinstance(value,dict):return "{\n"+"\n".join("\t"*(level+1)+json.dumps(str(k))+" = "+encode(v,level+1)+";" for k,v in value.items())+"\n"+"\t"*level+"}"
    if isinstance(value,list):return "("+", ".join(encode(x,level+1) for x in value)+")"
    if isinstance(value,int):return str(value)
    return json.dumps(str(value),ensure_ascii=False)
project=ROOT/"ClashDash.xcodeproj";project.mkdir(exist_ok=True)
(project/"project.pbxproj").write_text("// !$*UTF8*$!\n"+encode({"archiveVersion":1,"classes":{},"objectVersion":60,"objects":objects,"rootObject":project_id})+"\n")
schemes=project/"xcshareddata/xcschemes";schemes.mkdir(parents=True,exist_ok=True)
def entry(target,product,name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:ClashDash.xcodeproj"/>'
(schemes/"ClashDash.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{entry(app_id,'DashInto.app','ClashDash')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{entry(test_id,'ClashDashUITests.xctest','ClashDashUITests')}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{entry(app_id,'DashInto.app','ClashDash')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{entry(app_id,'DashInto.app','ClashDash')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(project)
