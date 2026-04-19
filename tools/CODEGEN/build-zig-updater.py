#!/usr/bin/env python3
"""
OmniBus Blockchain Core — build.zig Updater

Automatically adds a new core/*.zig module to build.zig test steps.
"""

import argparse
import os
import re
import sys
from typing import Any

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def add_module(build_file: str, module_file: str, step_name: str, test_step: str) -> bool:
    if not os.path.isfile(build_file):
        cprint(RED, f"build.zig not found: {build_file}")
        return False

    with open(build_file, "r", encoding="utf-8") as f:
        content = f.read()

    zig_path = f"core/{module_file}"
    add_line = f"    test_{step_name}_step.dependOn(&addTest(b, \"{step_name}\",  \"{zig_path}\", target, optimize).step);"

    # Find the target step block
    pattern = re.compile(rf"(const test_{test_step}_step = b\.step\(\"{test_step}\".*?\n)(.*?)(?=const test_|$)", re.DOTALL)
    m = pattern.search(content)
    if not m:
        cprint(YELLOW, f"Step '{test_step}' not found, appending near end of file")
        content = content.rstrip() + "\n" + add_line + "\n"
    else:
        insert_pos = m.end(2)
        content = content[:insert_pos] + add_line + "\n" + content[insert_pos:]

    with open(build_file, "w", encoding="utf-8") as f:
        f.write(content)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Add a new core module to build.zig")
    parser.add_argument("module", help="Module file name (e.g. new_module.zig)")
    parser.add_argument("--step-name", help="Short test name (e.g. new-module)")
    parser.add_argument("--test-step", default="test-crypto", help="Which build step to append to")
    parser.add_argument("--build-file", default="build.zig", help="Path to build.zig")
    args = parser.parse_args()

    step_name = args.step_name or args.module.replace(".zig", "").replace("_", "-")
    cprint(GREEN, "=== OmniBus build.zig Updater ===")
    ok = add_module(args.build_file, args.module, step_name, args.test_step)
    if ok:
        cprint(GREEN, f"Added '{step_name}' -> {args.build_file} under step '{args.test_step}'")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
