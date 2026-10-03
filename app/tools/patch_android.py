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
GROOVY = os.path.join(APP_DIR, "build.gradle")
KTS = os.path.join(APP_DIR, "build.gradle.kts")

DESUGAR_DEP_GROOVY = "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'"
DESUGAR_DEP_KTS = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'


def log(msg):
    print(f"[patch_android] {msg}")


def patch_groovy(path):
    with open(path, "r", encoding="utf-8") as f:
        src = f.read()
    original = src

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
        log("Contents: " + str(os.listdir(os.path.join(APP_DIR, "..")) if os.path.exists(os.path.join(APP_DIR, "..")) else "N/A"))
        sys.exit(1)
    log("done")


if __name__ == "__main__":
    main()
