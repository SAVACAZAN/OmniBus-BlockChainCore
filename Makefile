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
	@echo "Running:"
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

# Running
run-node: build-core
	@echo "Starting OmniBus Blockchain Node..."
	./omnibus-node

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
