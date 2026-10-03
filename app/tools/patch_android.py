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
