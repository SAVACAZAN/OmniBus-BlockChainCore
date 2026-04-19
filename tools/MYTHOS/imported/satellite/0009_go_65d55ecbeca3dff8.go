// vm_overflow.go
// EVM: overflow în MUL/SMUL
func VmOverflowExploit() {
    // Calculează 2^256 * 2^256
    // PC: PUSH32 0xffff..., PUSH32 0xffff..., MUL
}