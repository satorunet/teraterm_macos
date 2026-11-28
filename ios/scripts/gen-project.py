#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""TeraSP.xcodeproj を作る (App/ の .swift と Resources/ を全部入れる)。ファイルを足したらもう一度実行する。
パッケージ (このフォルダの Package.swift: TeraCore・CSSH2) はローカルのパッケージとして読む。"""
import os, hashlib, io
HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def uid(*k): return hashlib.md5("/".join(k).encode()).hexdigest()[:24].upper()
swift = sorted(f for f in os.listdir(os.path.join(HERE, "App")) if f.endswith(".swift"))
res = sorted(f for f in os.listdir(os.path.join(HERE, "Resources"))) if os.path.isdir(os.path.join(HERE, "Resources")) else []
products = ["TeraCore", "CSSH2"]
L = []
def w(s=""): L.append(s)
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 55;\n\tobjects = {\n")
w("/* Begin PBXBuildFile section */")
for f in swift: w(f'\t\t{uid("bf",f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {uid("fr",f)} /* {f} */; }};')
for f in res: w(f'\t\t{uid("bfr",f)} /* {f} in Resources */ = {{isa = PBXBuildFile; fileRef = {uid("frr",f)} /* {f} */; }};')
for p in products: w(f'\t\t{uid("bfp",p)} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {uid("dep",p)} /* {p} */; }};')
w("/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */")
for f in swift: w(f'\t\t{uid("fr",f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{f}"; sourceTree = "<group>"; }};')
for f in res:
    t = "folder.assetcatalog" if f.endswith(".xcassets") else ("folder" if os.path.isdir(os.path.join(HERE,"Resources",f)) else "file")
    w(f'\t\t{uid("frr",f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {t}; path = "{f}"; sourceTree = "<group>"; }};')
w(f'\t\t{uid("app")} /* TeraSP.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TeraSP.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
w(f'\t\t{uid("pkg")} /* TeraSP */ = {{isa = PBXFileReference; lastKnownFileType = folder; name = TeraSP; path = .; sourceTree = "<group>"; }};')
w("/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */")
w(f'\t\t{uid("fw")} = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n' + "".join(f'\t\t\t\t{uid("bfp",p)},\n' for p in products) + '\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};')
w("/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */")
w(f'\t\t{uid("main")} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{uid("pkg")},\n\t\t\t\t{uid("gapp")},\n\t\t\t\t{uid("gres")},\n\t\t\t\t{uid("gprod")},\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t}};')
w(f'\t\t{uid("gapp")} /* App */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{uid("fr",f)},\n' for f in swift) + '\t\t\t);\n\t\t\tpath = App;\n\t\t\tsourceTree = "<group>";\n\t\t};')
w(f'\t\t{uid("gres")} /* Resources */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' + "".join(f'\t\t\t\t{uid("frr",f)},\n' for f in res) + '\t\t\t);\n\t\t\tpath = Resources;\n\t\t\tsourceTree = "<group>";\n\t\t};')
w(f'\t\t{uid("gprod")} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{uid("app")},\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t}};')
w("/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */")
w(f'''\t\t{uid("tgt")} /* TeraSP */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {uid("tcl")};
\t\t\tbuildPhases = (
\t\t\t\t{uid("src")},
\t\t\t\t{uid("fw")},
\t\t\t\t{uid("rsc")},
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = TeraSP;
\t\t\tpackageProductDependencies = (
''' + "".join(f'\t\t\t\t{uid("dep",p)},\n' for p in products) + f'''\t\t\t);
\t\t\tproductName = TeraSP;
\t\t\tproductReference = {uid("app")};
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};''')
w("/* End PBXNativeTarget section */\n\n/* Begin PBXProject section */")
w(f'''\t\t{uid("proj")} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tLastSwiftUpdateCheck = 1310;
\t\t\t\tLastUpgradeCheck = 1310;
\t\t\t}};
\t\t\tbuildConfigurationList = {uid("pcl")};
\t\t\tcompatibilityVersion = "Xcode 13.0";
\t\t\tdevelopmentRegion = ja;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\tja,
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {uid("main")};
\t\t\tproductRefGroup = {uid("gprod")};
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{uid("tgt")},
\t\t\t);
\t\t}};''')
w("/* End PBXProject section */\n\n/* Begin PBXResourcesBuildPhase section */")
w(f'\t\t{uid("rsc")} = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n' + "".join(f'\t\t\t\t{uid("bfr",f)},\n' for f in res) + '\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};')
w("/* End PBXResourcesBuildPhase section */\n\n/* Begin PBXSourcesBuildPhase section */")
w(f'\t\t{uid("src")} = {{\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n' + "".join(f'\t\t\t\t{uid("bf",f)},\n' for f in swift) + '\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};')
w("/* End PBXSourcesBuildPhase section */\n\n/* Begin XCBuildConfiguration section */")
common = {"ALWAYS_SEARCH_USER_PATHS":"NO","CLANG_ENABLE_MODULES":"YES","IPHONEOS_DEPLOYMENT_TARGET":"15.0","SDKROOT":"iphoneos","SWIFT_VERSION":"5.0","ENABLE_BITCODE":"NO"}
tgt = {"PRODUCT_NAME":"TeraSP","PRODUCT_BUNDLE_IDENTIFIER":"net.satoru.terasp","GENERATE_INFOPLIST_FILE":"YES",
       "INFOPLIST_KEY_CFBundleDisplayName":'"Tera Term SP"',"INFOPLIST_KEY_UILaunchScreen_Generation":"YES",
       "INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents":"YES","INFOPLIST_KEY_UIRequiresFullScreen":"NO",
       "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone":'"UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
       "INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad":'"UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"',
       "INFOPLIST_KEY_NSLocalNetworkUsageDescription":'"同じネットワークの機器 (サーバー・ルーター・Tera Term Mac など) につなぐために使います"',
       "TARGETED_DEVICE_FAMILY":'"1,2"',"MARKETING_VERSION":"0.1.0",
       # ビルド番号: GitHub Actions では実行の番号 (TestFlight は毎回大きくする)
       "CURRENT_PROJECT_VERSION":os.environ.get("TERASP_BUILD","1"),"CODE_SIGN_STYLE":"Automatic","DEVELOPMENT_TEAM":"99NFJH4MCR",
       "LD_RUNPATH_SEARCH_PATHS":'"$(inherited) @executable_path/Frameworks"',"ASSETCATALOG_COMPILER_APPICON_NAME":"AppIcon",
       # ファイル App に「Tera Term SP」フォルダを出す (keys・macros を入れられる)
       "INFOPLIST_KEY_UIFileSharingEnabled":"YES","INFOPLIST_FILE":"Info.plist","INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace":"YES"}
def conf(key, name, d):
    body = "".join(f'\t\t\t\t{k} = {v};\n' for k,v in sorted(d.items()))
    w(f'\t\t{uid(key,name)} /* {name} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{body}\t\t\t}};\n\t\t\tname = {name};\n\t\t}};')
for n in ["Debug","Release"]:
    d = dict(common); d.update({"SWIFT_OPTIMIZATION_LEVEL": '"-Onone"' if n=="Debug" else '"-O"', "ONLY_ACTIVE_ARCH": "YES" if n=="Debug" else "NO"})
    if n=="Debug": d["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]="DEBUG"
    conf("pc", n, d); conf("tc", n, tgt)
w("/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */")
for key, ck in [("pcl","pc"),("tcl","tc")]:
    w(f'\t\t{uid(key)} = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{uid(ck,"Debug")},\n\t\t\t\t{uid(ck,"Release")},\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};')
w("/* End XCConfigurationList section */\n\n/* Begin XCSwiftPackageProductDependency section */")
for p in products: w(f'\t\t{uid("dep",p)} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {p};\n\t\t}};')
w(f'/* End XCSwiftPackageProductDependency section */\n\t}};\n\trootObject = {uid("proj")};\n}}\n')
d = os.path.join(HERE, "TeraSP.xcodeproj"); os.makedirs(d, exist_ok=True)
io.open(os.path.join(d, "project.pbxproj"), "w", encoding="utf-8").write("\n".join(L))
print("TeraSP.xcodeproj: %d swift, %d resources" % (len(swift), len(res)))
