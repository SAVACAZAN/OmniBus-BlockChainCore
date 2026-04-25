package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"time"
)

type Transaction struct {
	From      string `json:"from"`
	To        string `json:"to"`
	Amount    uint64 `json:"amount"`
	Signature string `json:"signature"`
}

type Block struct {
	Height    uint64         `json:"height"`
	Timestamp int64          `json:"timestamp"`
	PrevHash  string         `json:"prev_hash"`
	Merkle    string         `json:"merkle"`
	Nonce     uint64         `json:"nonce"`
	Txs       [3]Transaction `json:"txs"`
}

func main() {
	// ---------------- BENCH 1: SHA-256 (1M iter) ----------------
	{
		var input [64]byte
		for i := range input {
			input[i] = byte(i & 0xff)
		}
		const N = 1_000_000
		start := time.Now()
		var out [32]byte
		for i := 0; i < N; i++ {
			out = sha256.Sum256(input[:])
			input[0] ^= out[0]
		}
		dur := time.Since(start)
		ms := dur.Milliseconds()
		avgNs := dur.Nanoseconds() / int64(N)
		fmt.Printf("SHA256: %d ms (%d iterations, %d ns avg)\n", ms, N, avgNs)
	}

	// ---------------- BENCH 2: JSON serde (100K) ----------------
	{
		var raw32 [32]byte
		for i := range raw32 {
			raw32[i] = byte(i)
		}
		prevHex := hex.EncodeToString(raw32[:])
		merkleHex := hex.EncodeToString(raw32[:])
		var rawSig [64]byte
		for i := range rawSig {
			rawSig[i] = byte(i)
		}
		sigHex := hex.EncodeToString(rawSig[:])

		block := Block{
			Height:    12345,
			Timestamp: 1735689600,
			PrevHash:  prevHex,
			Merkle:    merkleHex,
			Nonce:     987654321,
			Txs: [3]Transaction{
				{From: "alice", To: "bob", Amount: 100, Signature: sigHex},
				{From: "carol", To: "dave", Amount: 200, Signature: sigHex},
				{From: "eve", To: "frank", Amount: 300, Signature: sigHex},
			},
		}

		const N = 100_000
		var sum uint64
		start := time.Now()
		for i := 0; i < N; i++ {
			data, err := json.Marshal(&block)
			if err != nil {
				panic(err)
			}
			var b2 Block
			if err := json.Unmarshal(data, &b2); err != nil {
				panic(err)
			}
			sum += b2.Height
		}
		dur := time.Since(start)
		ms := dur.Milliseconds()
		avgNs := dur.Nanoseconds() / int64(N)
		fmt.Printf("JSON: %d ms (%d iterations, %d ns avg) [sum=%d]\n", ms, N, avgNs, sum)
	}

	// ---------------- BENCH 3: HMAC-SHA256 (100K) ----------------
	{
		var key [32]byte
		for i := range key {
			key[i] = byte(i)
		}
		var msg [256]byte
		for i := range msg {
			msg[i] = byte(i & 0xff)
		}
		const N = 100_000
		start := time.Now()
		for i := 0; i < N; i++ {
			h := hmac.New(sha256.New, key[:])
			h.Write(msg[:])
			out := h.Sum(nil)
			msg[0] ^= out[0]
		}
		dur := time.Since(start)
		ms := dur.Milliseconds()
		avgNs := dur.Nanoseconds() / int64(N)
		fmt.Printf("HMAC: %d ms (%d iterations, %d ns avg)\n", ms, N, avgNs)
	}

	// ---------------- BENCH 4: Memory allocation (1M x 64B) ----------------
	{
		const N = 1_000_000
		ptrs := make([][]byte, N)
		start := time.Now()
		for i := 0; i < N; i++ {
			b := make([]byte, 64)
			b[0] = byte(i & 0xff)
			ptrs[i] = b
		}
		// "free" — clear refs (Go GC)
		for i := 0; i < N; i++ {
			ptrs[i] = nil
		}
		dur := time.Since(start)
		ms := dur.Milliseconds()
		avgNs := dur.Nanoseconds() / int64(N)
		fmt.Printf("MEMALLOC: %d ms (%d iterations, %d ns avg)\n", ms, N, avgNs)
		_ = ptrs
	}
}
