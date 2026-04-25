/* MSVC compatibility shims for Zig (MinGW ABI) consuming a Rust MSVC staticlib.
 *
 * The Rust toolchain on x86_64-pc-windows-msvc emits references to _fltused
 * (a flag indicating the binary uses floating-point) and to MSVC math/runtime
 * helpers that the GNU/MinGW lld-link toolchain shipped with Zig does not
 * provide. We define them here as minimal stubs so the link succeeds.
 *
 * Compile with: zig cc -target x86_64-windows-gnu -c msvc_compat.c
 */

/* _fltused is just a flag; MSVC sets it to 0x9875, value irrelevant. */
int _fltused = 0x9875;
