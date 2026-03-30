# OmniBus Blockchain Node — Docker Image
# ========================================
# Build: docker build -t omnibus-node .
# Run:   docker run -p 8332:8332 -p 8333:8333 -p 8334:8334 omnibus-node
# Mine:  docker run -e OMNIBUS_MNEMONIC="your 12 words" omnibus-node --mode miner --seed-host seed1.omnibus.network --seed-port 8333

FROM ubuntu:22.04 AS builder

# Install Zig
RUN apt-get update && apt-get install -y wget xz-utils && \
    wget -q https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz && \
    tar xf zig-linux-x86_64-0.15.2.tar.xz && \
    mv zig-linux-x86_64-0.15.2 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig && \
    rm zig-linux-x86_64-0.15.2.tar.xz

# Copy source
WORKDIR /build
COPY core/ core/
COPY agent/ agent/
COPY test/ test/
COPY build.zig .
COPY omnibus.toml .

# Build natively on Linux (no cross-compile needed inside Docker)
# -Doqs=false because liboqs Windows .a not available in container
RUN zig build -Doqs=false 2>&1 || echo "Build with defaults" && zig build -Doqs=false 2>&1

# Runtime image (minimal)
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

WORKDIR /omnibus

# Copy binaries
COPY --from=builder /build/zig-out/bin/omnibus-node /omnibus/omnibus-node
COPY --from=builder /build/zig-out/bin/omnibus-rpc /omnibus/omnibus-rpc
COPY --from=builder /build/omnibus.toml /omnibus/omnibus.toml

# Ports: RPC, P2P, WebSocket
EXPOSE 8332 8333 8334

# Data volume (chain persistence)
VOLUME /omnibus/data

# Default: start as miner
ENV OMNIBUS_MNEMONIC=""
ENV NODE_ID="docker-node"

ENTRYPOINT ["/omnibus/omnibus-node"]
CMD ["--mode", "miner", "--node-id", "docker-node", "--seed-host", "seed1.omnibus.network", "--seed-port", "8333"]
