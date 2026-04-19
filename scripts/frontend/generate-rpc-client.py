#!/usr/bin/env python3
"""
OmniBus Blockchain Core — TypeScript RPC Client Generator

Reads core/rpc_server.zig, extracts all JSON-RPC method names from
std.mem.eql(u8, method, "...") patterns, and generates a TypeScript
RPC client class with a typed method for each. Output to stdout.
"""

import os
import re
import sys

# ANSI colors (stderr only, stdout is the generated code)
GREEN = "\033[92m"
YELLOW = "\033[93m"
DIM = "\033[2m"
RESET = "\033[0m"


def log(msg: str) -> None:
    """Print to stderr so stdout stays clean for the generated code."""
    print(msg, file=sys.stderr)


def find_rpc_server_zig() -> str:
    """Locate core/rpc_server.zig relative to this script's project root."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.abspath(os.path.join(script_dir, "..", ".."))
    candidate = os.path.join(project_root, "core", "rpc_server.zig")
    if os.path.isfile(candidate):
        return candidate
    # Fallback: try current directory
    if os.path.isfile("core/rpc_server.zig"):
        return os.path.abspath("core/rpc_server.zig")
    return candidate  # return expected path for error message


def extract_rpc_methods(filepath: str) -> list[dict]:
    """
    Extract RPC method names from rpc_server.zig by matching:
      std.mem.eql(u8, method, "methodname")

    Also tries to extract parameter hints from nearby Usage comments.
    """
    with open(filepath, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()

    # Find all method string literals
    pattern = re.compile(r'std\.mem\.eql\(u8,\s*method,\s*"([a-zA-Z_][a-zA-Z0-9_]*)"\)')
    raw_methods = pattern.findall(content)

    # Deduplicate while preserving order
    seen = set()
    methods = []
    for name in raw_methods:
        if name not in seen:
            seen.add(name)
            methods.append(name)

    # Try to extract parameter info from Usage comments
    # Pattern: /// Usage: {"method":"NAME","params":["param1","param2",...],"id":1}
    usage_pattern = re.compile(
        r'///\s*Usage:\s*\{[^}]*"method"\s*:\s*"([^"]+)"[^}]*"params"\s*:\s*\[([^\]]*)\]',
        re.MULTILINE,
    )
    usage_params: dict[str, list[str]] = {}
    for m in usage_pattern.finditer(content):
        method_name = m.group(1)
        params_raw = m.group(2).strip()
        if params_raw:
            # Extract param names/types from the usage example
            params = []
            for p in re.findall(r'"([^"]*)"', params_raw):
                params.append(p)
            # Also catch numeric placeholders like count, amount_sat
            for p in re.findall(r'\b([a-z_]+(?:_[a-z]+)*)\b', params_raw):
                if p not in params and p not in ("true", "false"):
                    params.append(p)
            usage_params[method_name] = params

    result = []
    for name in methods:
        entry = {"name": name, "params": []}
        if name in usage_params:
            for i, p in enumerate(usage_params[name]):
                # Infer type from name
                if any(kw in p for kw in ["hash", "hex", "addr", "address", "data", "string", "id"]):
                    ptype = "string"
                elif any(kw in p for kw in ["height", "count", "amount", "fee", "sat", "port", "nonce"]):
                    ptype = "number"
                else:
                    ptype = "string"
                param_name = re.sub(r'[^a-zA-Z0-9_]', '_', p).strip('_') or f"param{i}"
                entry["params"].append({"name": param_name, "type": ptype})
        result.append(entry)

    return result


def generate_typescript(methods: list[dict], class_name: str = "OmniBusRPC") -> str:
    """Generate a TypeScript RPC client class."""
    lines = [
        "// =============================================================================",
        "// OmniBus Blockchain Core — Auto-generated TypeScript RPC Client",
        f"// Generated from core/rpc_server.zig ({len(methods)} methods)",
        "// Do not edit manually — regenerate with: python scripts/frontend/generate-rpc-client.py",
        "// =============================================================================",
        "",
        "export interface RPCResponse<T = unknown> {",
        "  jsonrpc: string;",
        "  id: number;",
        "  result?: T;",
        "  error?: { code: number; message: string };",
        "}",
        "",
        f"export class {class_name} {{",
        "  private url: string;",
        "  private nextId = 1;",
        "",
        "  constructor(url: string = 'http://127.0.0.1:8332') {",
        "    this.url = url;",
        "  }",
        "",
        "  private async call<T = unknown>(method: string, params: unknown[] = []): Promise<T> {",
        "    const id = this.nextId++;",
        "    const res = await fetch(this.url, {",
        "      method: 'POST',",
        "      headers: { 'Content-Type': 'application/json' },",
        "      body: JSON.stringify({ jsonrpc: '2.0', id, method, params }),",
        "    });",
        "    if (!res.ok) {",
        "      throw new Error(`HTTP ${res.status}: ${res.statusText}`);",
        "    }",
        "    const data: RPCResponse<T> = await res.json();",
        "    if (data.error) {",
        "      throw new Error(`RPC ${data.error.code}: ${data.error.message}`);",
        "    }",
        "    return data.result as T;",
        "  }",
        "",
    ]

    for m in methods:
        name = m["name"]
        params = m.get("params", [])

        # Build typed parameter list
        if params:
            args_typed = ", ".join(f"{p['name']}: {p['type']}" for p in params)
            args_pass = ", ".join(p["name"] for p in params)
        else:
            args_typed = ""
            args_pass = ""

        # Camel-case method name for the TS function
        ts_name = name

        lines.append(f"  /** JSON-RPC method: {name} */")
        lines.append(f"  async {ts_name}({args_typed}): Promise<unknown> {{")
        lines.append(f"    return this.call('{name}', [{args_pass}]);")
        lines.append("  }")
        lines.append("")

    lines.append("}")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    zig_path = find_rpc_server_zig()

    if not os.path.isfile(zig_path):
        log(f"{YELLOW}[WARN] Cannot find {zig_path}{RESET}")
        log(f"{YELLOW}[WARN] Generating client with empty method list{RESET}")
        methods = []
    else:
        log(f"{GREEN}[OK]{RESET} Reading {zig_path}")
        methods = extract_rpc_methods(zig_path)
        log(f"{GREEN}[OK]{RESET} Extracted {len(methods)} RPC methods")

        # Log method names
        for m in methods:
            params_str = ", ".join(f"{p['name']}:{p['type']}" for p in m.get("params", []))
            log(f"{DIM}  - {m['name']}({params_str}){RESET}")

    ts_code = generate_typescript(methods)
    print(ts_code)

    log(f"\n{GREEN}[DONE]{RESET} TypeScript client written to stdout")
    log(f"{DIM}Pipe to file: python generate-rpc-client.py > frontend/src/api/rpc-client.generated.ts{RESET}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
