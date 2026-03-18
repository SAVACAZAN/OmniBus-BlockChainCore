.PHONY: build build-core build-agent run-node run-rpc run-frontend test clean help

# Zig compiler
ZIG := zig
ZIG_FLAGS := -O ReleaseFast

# Node commands
NODE := node
NPM := npm

# Build directories
BUILD_DIR := zig-cache
FRONTEND_DIR := frontend

help:
	@echo "OmniBus BlockChain Core - Build Commands"
	@echo ""
	@echo "Blockchain (Zig):"
	@echo "  make build-core       - Build blockchain node executable"
	@echo "  make build-rpc        - Build RPC server executable"
	@echo "  make build-agent      - Build agent system executable"
	@echo "  make build            - Build all Zig components"
	@echo ""
	@echo "Frontend (TypeScript):"
	@echo "  make install-frontend - npm install for frontend"
	@echo "  make build-frontend   - Build React explorer & wallet"
	@echo ""
	@echo "Running (with Network):"
	@echo "  make run-seed-primary - Start primary seed node (port 9000)"
	@echo "  make run-seed-2       - Start secondary seed node (port 9001)"
	@echo "  make run-miner-1      - Start miner 1 (2000 H/s)"
	@echo "  make run-miner-2      - Start miner 2 (1500 H/s)"
	@echo "  make run-miner-3      - Start miner 3 (1800 H/s)"
	@echo ""
	@echo "Legacy:"
	@echo "  make run-node         - Start blockchain node (mining)"
	@echo "  make run-rpc          - Start JSON-RPC server"
	@echo "  make run-frontend     - Start React dev server"
	@echo ""
	@echo "Testing & Cleanup:"
	@echo "  make test             - Run Zig tests"
	@echo "  make clean            - Remove build artifacts"

# Core Blockchain Build
build-core:
	@echo "Building OmniBus Blockchain Node..."
	$(ZIG) build-exe $(ZIG_FLAGS) core/main.zig -o omnibus-node

build-rpc:
	@echo "Building RPC Server..."
	$(ZIG) build-exe $(ZIG_FLAGS) core/rpc_server.zig -o omnibus-rpc

build-agent:
	@echo "Building Agent System..."
	$(ZIG) build-exe $(ZIG_FLAGS) agent/agent_manager.zig -o omnibus-agent

build: build-core build-rpc build-agent
	@echo "✅ All Zig components built successfully"
	@ls -la omnibus-* 2>/dev/null | awk '{print "  " $$9, "(" $$5 " bytes)"}'

# Frontend Build
install-frontend:
	@echo "Installing frontend dependencies..."
	cd $(FRONTEND_DIR) && $(NPM) install

build-frontend: install-frontend
	@echo "Building React frontend..."
	cd $(FRONTEND_DIR) && $(NPM) run build
	@echo "✅ Frontend built to $(FRONTEND_DIR)/dist"

# Running - Network Setup
run-seed-primary: build-core
	@echo "Starting Primary Seed Node..."
	./omnibus-node --mode seed --node-id seed-1 --primary --port 9000

run-seed-2: build-core
	@echo "Starting Secondary Seed Node..."
	./omnibus-node --mode seed --node-id seed-2 --port 9001

run-miner-1: build-core
	@echo "Starting Miner 1 (2000 H/s)..."
	./omnibus-node --mode miner --node-id miner-1 --host 127.0.0.1 --port 9011 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 2000

run-miner-2: build-core
	@echo "Starting Miner 2 (1500 H/s)..."
	./omnibus-node --mode miner --node-id miner-2 --host 127.0.0.1 --port 9012 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 1500

run-miner-3: build-core
	@echo "Starting Miner 3 (1800 H/s)..."
	./omnibus-node --mode miner --node-id miner-3 --host 127.0.0.1 --port 9013 --seed-host 127.0.0.1 --seed-port 9000 --hashrate 1800

# Running - Legacy
run-node: build-core
	@echo "Starting OmniBus Blockchain Node..."
	./omnibus-node --mode seed --node-id seed-1 --primary --port 9000

run-rpc: build-rpc
	@echo "Starting JSON-RPC Server..."
	./omnibus-rpc

run-frontend: install-frontend
	@echo "Starting React development server..."
	cd $(FRONTEND_DIR) && $(NPM) run dev

# Testing
test:
	@echo "Running Zig tests..."
	$(ZIG) build test
	@echo "✅ Tests passed"

# Cleanup
clean:
	@echo "Cleaning build artifacts..."
	rm -f omnibus-node omnibus-rpc omnibus-agent
	rm -rf $(BUILD_DIR)
	rm -rf $(FRONTEND_DIR)/dist
	rm -rf $(FRONTEND_DIR)/node_modules
	@echo "✅ Cleanup complete"

# Docker support
docker-build:
	@echo "Building Docker image..."
	docker build -t omnibus-blockchain:latest .

docker-run:
	@echo "Running in Docker..."
	docker-compose up -d
	@echo "✅ Running on http://localhost:5173"

# Git commands
git-init:
	git init
	git add -A
	git commit -m "Phase 73: OmniBus BlockChain Core - Zig + TypeScript"

git-push:
	git push -u origin main

# All in one
all: build build-frontend
	@echo "✅ Complete build finished"
	@echo ""
	@echo "To run:"
	@echo "  Terminal 1: make run-node"
	@echo "  Terminal 2: make run-rpc"
	@echo "  Terminal 3: make run-frontend"
	@echo ""
	@echo "Then visit: http://localhost:5173"
