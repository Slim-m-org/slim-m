# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The connector supervisor (decision 0134): one static musl binary on distroless,
# built natively per architecture like the server image (no QEMU). The same image
# runs the supervisor, each connector's egress gateway and the volume chown helper.

FROM rust:1.97.1-alpine@sha256:3c38f3f82c2f3d73da3b38e18d279393a04cb43ddded0e35088a8c3324d40900 AS builder
RUN apk add --no-cache musl-dev
WORKDIR /build

# Manifests and empty sources only, so this stage rebuilds when a dependency changes and not on every source edit.
FROM builder AS deps
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY .cargo .cargo
COPY crates/slimm-supervisor/Cargo.toml crates/slimm-supervisor/Cargo.toml
# The server's manifest too, with stubs, so the workspace matches Cargo.lock; only the supervisor is built.
COPY crates/slimm-server/Cargo.toml crates/slimm-server/Cargo.toml
RUN mkdir -p crates/slimm-supervisor/src crates/slimm-server/src crates/slimm-server/benches \
    && touch crates/slimm-supervisor/src/lib.rs crates/slimm-server/src/lib.rs \
    && echo 'fn main() {}' | tee crates/slimm-supervisor/src/main.rs crates/slimm-server/src/main.rs > crates/slimm-server/benches/hot_paths.rs \
    && cargo build --locked --release --bin slimm-supervisor \
    && cargo clean --release --package slimm-supervisor

FROM deps AS release
COPY crates/slimm-supervisor/src crates/slimm-supervisor/src
RUN cargo build --locked --release --bin slimm-supervisor \
    && cp target/release/slimm-supervisor /slimm-supervisor

FROM gcr.io/distroless/static-debian12:nonroot@sha256:1b7b9f0f0e0a1d2155f531db587cc48ec26aaf97ab64364225f5bf18a054e66a
COPY --from=release /slimm-supervisor /usr/local/bin/slimm-supervisor
USER nonroot
ENTRYPOINT ["/usr/local/bin/slimm-supervisor"]
