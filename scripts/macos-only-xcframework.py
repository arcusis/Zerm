#!/usr/bin/env python3
"""Derive a macOS-only variant of whisper.cpp's or llama.cpp's build-xcframework.sh.

The upstream scripts build seven slices (iOS, visionOS and tvOS, each with a simulator, plus
macOS) and Zerm only links the macOS one. Dropping the other six cuts the native build to a
fraction of its time, locally and in CI.

usage: macos-only-xcframework.py <upstream build-xcframework.sh> <output script>

Fails instead of writing a script when the upstream layout no longer matches, so a changed
recipe is noticed rather than silently producing a different framework.
"""
import re
import sys

OTHER_BUILD_DIR = re.compile(r"build-(ios|visionos|tvos)")
PLATFORM_BLOCK = re.compile(r'^echo "Building for (.+)\.\.\."')


def transform(lines):
    output, skipping, dropped_blocks = [], False, 0
    for line in lines:
        block = PLATFORM_BLOCK.match(line)
        if block and block.group(1) != "macOS":
            skipping, dropped_blocks = True, dropped_blocks + 1
            continue
        if skipping:
            if line.startswith("cmake --build "):
                skipping = False
            continue
        stripped = line.lstrip()
        if OTHER_BUILD_DIR.search(line) and (
            stripped.startswith(("setup_framework_structure", "combine_static_libraries", "-framework", "-debug-symbols"))
        ):
            continue
        output.append(line)
    return output, dropped_blocks


def main():
    source, destination = sys.argv[1], sys.argv[2]
    lines = open(source, encoding="utf-8").read().splitlines(keepends=True)
    output, dropped_blocks = transform(lines)
    text = "".join(output)

    problems = []
    if dropped_blocks != 6:
        problems.append(f"expected 6 non-macOS build blocks, found {dropped_blocks}")
    if 'echo "Building for macOS..."' not in text:
        problems.append("the macOS build block is missing")
    if not re.search(r"-framework \$\(pwd\)/build-macos/framework/", text):
        problems.append("the XCFramework no longer includes the macOS framework")
    for command in ("setup_framework_structure", "combine_static_libraries", "-framework $(pwd)", "-debug-symbols"):
        if any(command in line and OTHER_BUILD_DIR.search(line) for line in output):
            problems.append(f"a non-macOS '{command}' line survived")
    if problems:
        sys.exit(f"{source}: upstream layout changed: " + "; ".join(problems))

    with open(destination, "w", encoding="utf-8") as handle:
        handle.write(text)


if __name__ == "__main__":
    main()
