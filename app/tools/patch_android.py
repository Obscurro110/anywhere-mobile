#!/usr/bin/env python3
"""
Patch the Flutter-generated Android Gradle config so that plugins requiring
core library desugaring (e.g. flutter_local_notifications) can be built.

Run AFTER `flutter create .` (which generates android/), e.g. in CI:
    python3 tools/patch_android.py

Handles both Groovy (build.gradle) and Kotlin DSL (build.gradle.kts).
Idempotent: safe to run multiple times.
"""
import os
import re
import sys

APP_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "android", "app")
ANDROID_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "android")
GROOVY = os.path.join(APP_DIR, "build.gradle")
KTS = os.path.join(APP_DIR, "build.gradle.kts")
ROOT_GROOVY = os.path.join(ANDROID_DIR, "build.gradle")
ROOT_KTS = os.path.join(ANDROID_DIR, "build.gradle.kts")

DESUGAR_DEP_GROOVY = "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"
DESUGAR_DEP_KTS = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'

# Plugins (flutter_plugin_android_lifecycle via file_picker, etc.) require
# compiling against a recent Android API level.
TARGET_COMPILE_SDK = os.environ.get("ANDROID_COMPILE_SDK", "36")


def log(msg):
    print(f"[patch_android] {msg}")


def set_compile_sdk(src, kts):
    """Force compileSdk to TARGET_COMPILE_SDK (handles several template styles)."""
    if kts:
        # compileSdk = flutter.compileSdkVersion  ->  compileSdk = 36
        src, n1 = re.subn(r"compileSdk\s*=\s*flutter\.compileSdkVersion",
                          f"compileSdk = {TARGET_COMPILE_SDK}", src)
        # compileSdk = 34  ->  compileSdk = 36
        src, n2 = re.subn(r"compileSdk\s*=\s*\d+",
                          f"compileSdk = {TARGET_COMPILE_SDK}", src)
    else:
        # compileSdkVersion flutter.compileSdkVersion  ->  compileSdkVersion 36
        src, n1 = re.subn(r"compileSdkVersion\s+flutter\.compileSdkVersion",
                          f"compileSdkVersion {TARGET_COMPILE_SDK}", src)
        src, n2 = re.subn(r"compileSdkVersion\s+\d+",
                          f"compileSdkVersion {TARGET_COMPILE_SDK}", src)
        # compileSdk flutter.compileSdkVersion (newer groovy style)
        src, n1b = re.subn(r"compileSdk\s+flutter\.compileSdkVersion",
                           f"compileSdk {TARGET_COMPILE_SDK}", src)
        src, n2b = re.subn(r"compileSdk\s+\d+",
                           f"compileSdk {TARGET_COMPILE_SDK}", src)
    return src


def patch_groovy(path):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    original = src

    # 0) force compileSdk
    src = set_compile_sdk(src, kts=False)

    # 0.5) 固定 release 签名（读 android/key.properties）
    src = patch_signing_groovy(src)

    # 1) enable core library desugaring inside compileOptions { ... }
    if "coreLibraryDesugaringEnabled" not in src:
        def add_flag(m):
            body = m.group(1)
            indent = "        "
            return f"compileOptions {{{body.rstrip()}\n{indent}    coreLibraryDesugaringEnabled true\n{indent}}}\n"
        src, n = re.subn(r"compileOptions\s*\{(.*?)\}", add_flag, src, count=1, flags=re.S)
        log(f"compileOptions patched: {n}")

    # 2) add desugar dependency (create/append a dependencies block)
    if "desugar_jdk_libs" not in src:
        if re.search(r"^dependencies\s*\{", src, flags=re.M):
            src = re.sub(r"^dependencies\s*\{", "dependencies {\n    " + DESUGAR_DEP_GROOVY, src, count=1, flags=re.M)
        else:
            src += f"\n\ndependencies {{\n    {DESUGAR_DEP_GROOVY}\n}}\n"
        log("desugar dependency added")

    if src != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        log(f"wrote {path}")
    else:
        log("no change needed (gradle)")


def patch_kts(path):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    original = src

    # 0) force compileSdk
    src = set_compile_sdk(src, kts=True)

    # 0.5) 固定 release 签名
    src = patch_signing_kts(src)

    # 1) enable desugaring
    if "isCoreLibraryDesugaringEnabled" not in src:
        def add_flag(m):
            body = m.group(1)
            indent = "        "
            return f"compileOptions {{{body.rstrip()}\n{indent}    isCoreLibraryDesugaringEnabled = true\n{indent}}}\n"
        src, n = re.subn(r"compileOptions\s*\{(.*?)\}", add_flag, src, count=1, flags=re.S)
        log(f"compileOptions(kts) patched: {n}")

    # 2) dependency
    if "desugar_jdk_libs" not in src:
        if re.search(r"^dependencies\s*\{", src, flags=re.M):
            src = re.sub(r"^dependencies\s*\{", "dependencies {\n    " + DESUGAR_DEP_KTS, src, count=1, flags=re.M)
        else:
            src += f"\n\ndependencies {{\n    {DESUGAR_DEP_KTS}\n}}\n"
        log("desugar dependency added (kts)")

    if src != original:
        with open(path, "w", encoding="utf-8") as f:
            f.write(src)
        log(f"wrote {path}")
    else:
        log("no change needed (kts)")


MANIFEST = os.path.join(APP_DIR, "src", "main", "AndroidManifest.xml")

# App 内「检查更新 → 下载 → 安装」需要此权限才能在 Android 8+ 唤起安装器
INSTALL_PERMISSION = '<uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES" />'

# ---------------------------------------------------------------------------
# 固定 release 签名
# ---------------------------------------------------------------------------
# 没有固定签名时，Flutter 会用 debug 签名，而 CI 每次都是全新机器 ->
# 每次自动生成的 debug keystore 都不一样 -> 每次 APK 签名都不同 ->
# 覆盖安装时报「与已安装的应用签名不同」。
#
# 这里改成读取 android/key.properties（CI 从 Secrets 落盘），
# 让每次构建都用同一把钥匙，用户就能正常增量更新。
SIGN_MARKER = "// anywhere-mobile: release signing"
KEY_PROPS = "key.properties"


def _signing_snippet_groovy():
    return f"""
{SIGN_MARKER}
def anywhereKeystoreProperties = new Properties()
def anywhereKeystorePropertiesFile = rootProject.file("{KEY_PROPS}")
if (anywhereKeystorePropertiesFile.exists()) {{
    anywhereKeystoreProperties.load(new FileInputStream(anywhereKeystorePropertiesFile))
}}
"""


def _signing_config_groovy():
    return f"""    signingConfigs {{
        release {{
            if (anywhereKeystorePropertiesFile.exists()) {{
                keyAlias anywhereKeystoreProperties['keyAlias']
                keyPassword anywhereKeystoreProperties['keyPassword']
                storeFile file(anywhereKeystoreProperties['storeFile'])
                storePassword anywhereKeystoreProperties['storePassword']
                storeType anywhereKeystoreProperties['storeType'] ?: 'PKCS12'
            }}
        }}
    }}
"""


def _signing_snippet_kts():
    return f"""
{SIGN_MARKER}
import java.util.Properties
import java.io.FileInputStream
val anywhereKeystoreProperties = Properties()
val anywhereKeystorePropertiesFile = rootProject.file("{KEY_PROPS}")
if (anywhereKeystorePropertiesFile.exists()) {{
    anywhereKeystoreProperties.load(FileInputStream(anywhereKeystorePropertiesFile))
}}
"""


def _signing_config_kts():
    return """    signingConfigs {
        create("release") {
            if (anywhereKeystorePropertiesFile.exists()) {
                keyAlias = anywhereKeystoreProperties["keyAlias"] as String
                keyPassword = anywhereKeystoreProperties["keyPassword"] as String
                storeFile = file(anywhereKeystoreProperties["storeFile"] as String)
                storePassword = anywhereKeystoreProperties["storePassword"] as String
                storeType = (anywhereKeystoreProperties["storeType"] as String?) ?: "PKCS12"
            }
        }
    }
"""


def patch_signing_groovy(src):
    """注入 properties 加载 + signingConfigs + 把 release 指向它。"""
    if SIGN_MARKER in src:
        log("signing already patched (groovy); skipping")
        return src

    # 1) 在 plugins {} 之后插入 properties 加载
    m = re.search(r"^plugins\s*\{.*?^\}\s*$", src, flags=re.S | re.M)
    if m:
        src = src[:m.end()] + _signing_snippet_groovy() + src[m.end():]
    else:
        src = _signing_snippet_groovy() + "\n" + src

    # 2) 在 android { 里（buildTypes 之前）插入 signingConfigs
    m2 = re.search(r"^(\s*)buildTypes\s*\{", src, flags=re.M)
    if m2:
        src = src[:m2.start()] + _signing_config_groovy() + src[m2.start():]
    else:
        log("WARN: buildTypes not found; signingConfigs not injected")

    # 3) release 指向 signingConfigs.release
    src2, n = re.subn(r"signingConfig\s+signingConfigs\.debug",
                      "signingConfig signingConfigs.release", src)
    if n == 0:
        # 模板里可能没有 buildTypes.release 块 —— 补一个
        m3 = re.search(r"^(\s*)buildTypes\s*\{(.*?)^\1\}", src2, flags=re.S | re.M)
        if m3:
            body = m3.group(2)
            if "release" not in body:
                indent = m3.group(1) + "    "
                src2 = (src2[:m3.end(2)]
                        + f"{indent}release {{\n{indent}    signingConfig signingConfigs.release\n{indent}}}\n"
                        + src2[m3.end(2):])
                n = 1
    log(f"signingConfig -> release ({n} 处)")
    return src2


def patch_signing_kts(src):
    if SIGN_MARKER in src:
        log("signing already patched (kts); skipping")
        return src

    m = re.search(r"^plugins\s*\{.*?^\}\s*$", src, flags=re.S | re.M)
    if m:
        src = src[:m.end()] + _signing_snippet_kts() + src[m.end():]
    else:
        src = _signing_snippet_kts() + "\n" + src

    m2 = re.search(r"^(\s*)buildTypes\s*\{", src, flags=re.M)
    if m2:
        src = src[:m2.start()] + _signing_config_kts() + src[m2.start():]
    else:
        log("WARN: buildTypes not found; signingConfigs not injected")

    src2, n = re.subn(r"signingConfig\s*=\s*signingConfigs\.getByName\(\"debug\"\)",
                      "signingConfig = signingConfigs.getByName(\"release\")", src)
    if n == 0:
        src2, n = re.subn(r"signingConfig\s*=\s*signingConfigs\.debug",
                          "signingConfig = signingConfigs.getByName(\"release\")", src)
    if n == 0:
        src2, n = re.subn(r"signingConfig\s*=\s*signingConfigs\[\"debug\"\]",
                          "signingConfig = signingConfigs.getByName(\"release\")", src)
    log(f"signingConfig -> release (kts, {n} 处)")
    return src2


def patch_manifest():
    """加 REQUEST_INSTALL_PACKAGES（自更新用）。幂等。"""
    if not os.path.exists(MANIFEST):
        log(f"WARN: manifest not found at {MANIFEST}; skip install permission")
        return
    with open(MANIFEST, "r", encoding="utf-8") as f:
        src = f.read()
    if "REQUEST_INSTALL_PACKAGES" in src:
        log("manifest already has REQUEST_INSTALL_PACKAGES; skipping")
        return
    m = re.search(r"<manifest[^>]*>\s*", src)
    if not m:
        log("WARN: <manifest> tag not found; skip install permission")
        return
    insert_at = m.end()
    src = src[:insert_at] + f"    {INSTALL_PERMISSION}\n" + src[insert_at:]
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write(src)
    log("added REQUEST_INSTALL_PACKAGES to AndroidManifest.xml")


def main():
    if os.path.exists(KTS):
        log("found Kotlin DSL build.gradle.kts")
        patch_kts(KTS)
    elif os.path.exists(GROOVY):
        log("found Groovy build.gradle")
        patch_groovy(GROOVY)
    else:
        log(f"ERROR: neither build.gradle nor build.gradle.kts found under {APP_DIR}")
        sys.exit(1)

    # Force every plugin subproject to compile against TARGET_COMPILE_SDK.
    # Otherwise plugins (e.g. file_picker) compile against the Flutter default
    # (android-34) and fail AAR metadata checks against newer deps.
    patch_root_build()

    # App 内自更新：允许安装 APK
    patch_manifest()
    log("done")


MARKER = "// anywhere-mobile: force plugin compileSdk"

GROOVY_SUBPROJECTS = """
// anywhere-mobile: force plugin compileSdk
subprojects { sp ->
    sp.plugins.withId('com.android.library') {
        try { sp.android.compileSdkVersion {COMPILE_SDK} } catch (ignored) {}
    }
    sp.plugins.withId('com.android.application') {
        try { sp.android.compileSdkVersion {COMPILE_SDK} } catch (ignored) {}
    }
}
"""

# Set compileSdk AFTER each subproject is fully evaluated (afterEvaluate), so it
# overrides the value the plugin's own build.gradle sets (e.g. android-34).
# Flutter's root build calls evaluationDependsOn(':app'), which can make some
# projects already-evaluated -> guard with try/catch and fall back to immediate.
# withGroovyBuilder avoids needing AGP classes on the script classpath.
KTS_SUBPROJECTS = """
// anywhere-mobile: force plugin compileSdk
subprojects {
    val sp = this
    val cfg = {
        val a = sp.extensions.findByName("android")
        if (a != null) {
            var ok = false
            try {
                a.withGroovyBuilder { "compileSdkVersion"({COMPILE_SDK}) }
                ok = true
            } catch (e: Exception) { }
            if (!ok) {
                try {
                    val m = a.javaClass.methods.firstOrNull {
                        it.name == "compileSdkVersion" &&
                        it.parameterTypes.size == 1 &&
                        it.parameterTypes[0] == Int::class.javaPrimitiveType
                    }
                    if (m != null) { m.invoke(a, {COMPILE_SDK}); ok = true }
                } catch (e: Exception) { }
            }
            println("anywhere-mobile patch: " + sp.name + " compileSdk set = " + ok)
        }
    }
    try {
        sp.afterEvaluate { cfg() }
    } catch (e: Exception) {
        cfg()
    }
}
"""


def patch_root_build():
    if os.path.exists(ROOT_KTS):
        path, snippet = ROOT_KTS, KTS_SUBPROJECTS
    elif os.path.exists(ROOT_GROOVY):
        path, snippet = ROOT_GROOVY, GROOVY_SUBPROJECTS
    else:
        log("WARN: no root android/build.gradle(.kts) found; skipping plugin compileSdk override")
        return
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    if MARKER in src:
        log("root build already patched; skipping")
        return
    snippet = snippet.replace("{COMPILE_SDK}", TARGET_COMPILE_SDK)
    with open(path, "a", encoding="utf-8") as f:
        f.write("\n" + snippet + "\n")
    log(f"appended subprojects override to {os.path.basename(path)} (compileSdk={TARGET_COMPILE_SDK})")


if __name__ == "__main__":
    main()
