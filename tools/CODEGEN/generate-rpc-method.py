#!/usr/bin/env python3
"""
OmniBus Blockchain Core — RPC Method Generator

Generates a Zig handler stub in rpc_server.zig from method name + params.
"""

import argparse
import os
import sys
from typing import Any, Dict, List

GREEN = "\033[92m"
RED = "\033[91m"
YELLOW = "\033[93m"
RESET = "\033[0m"


def cprint(color: str, msg: str) -> None:
    print(f"{color}{msg}{RESET}")


def generate_handler(method: str, params: List[str]) -> str:
    func_name = method.replace(".", "_")
    param_parsing = ""
    for p in params:
        param_parsing += f"        const {p} = try req.getStringParam(\"{p}\");\n"

    zig = f"""
// Auto-generated RPC handler for {method}
fn handle_{func_name}(allocator: std.mem.Allocator, req: JsonRequest) !JsonValue {{
    // Parse parameters
{param_parsing}
    _ = allocator;
    // TODO: implement business logic
    return JsonValue{{ .object = .{{}} }};
}}
"""
    return zig


def inject_into_file(filepath: str, handler: str) -> bool:
    if not os.path.isfile(filepath):
        cprint(RED, f"File not found: {filepath}")
        return False
    with open(filepath, "r", encoding="utf-8") as f:
        content = f.read()
    marker = "// -- RPC method handlers --"
    if marker not in content:
        cprint(YELLOW, f"Marker not found in {filepath}, appending to end")
        content += "\n" + handler + "\n"
    else:
        content = content.replace(marker, handler + "\n" + marker)
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate Zig RPC handler stub")
    parser.add_argument("method", help="RPC method name (e.g. getblockchaininfo)")
    parser.add_argument("--params", nargs="*", default=[], help="Parameter names")
    parser.add_argument("--target", default="core/rpc_server.zig", help="File to inject into")
    args = parser.parse_args()

    cprint(GREEN, "=== OmniBus RPC Method Generator ===")
    handler = generate_handler(args.method, args.params)
    cprint(YELLOW, "Generated handler:\n" + handler)
    ok = inject_into_file(args.target, handler)
    if ok:
        cprint(GREEN, f"Injected into {args.target}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
