pub const BtcTxBuilder = struct {
    inputs: []UTXO,
    outputs: []Output,
    fee_rate: u64, // sat/vbyte
    
    pub fn build(self: *Self) ![]u8  // raw BTC transaction
    pub fn sign(self: *Self, key: *PrivateKey) !void
    pub fn finalize(self: *Self) ![]u8
}