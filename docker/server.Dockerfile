# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Production image for the slim-m home server.
#
# Three build stages (toolchain, dependencies, source) produce one static musl
# binary, then a distroless nonroot runtime ships it plus a nonroot-owned /data
# directory for the embedded SQLite database. The image uses the binary's own
# --healthcheck subcommand since distroless has no shell.
#
# Multi-arch: this Dockerfile builds natively for whatever platform it is invoked
# with (buildx pulls the matching target-arch base image), so `--platform
# linux/arm64` produces a real arm64 binary. Release builds one image per
# architecture on a native runner and merges them into one manifest (see
# .github/workflows/release.yml), so there is no slow QEMU cross-compilation and
# no cross-linking toolchain to maintain.

FROM rust:1.97.1-alpine@sha256:3c38f3f82c2f3d73da3b38e18d279393a04cb43ddded0e35088a8c3324d40900 AS builder
# make builds the bundled jemalloc (tikv-jemalloc-sys).
RUN apk add --no-cache musl-dev make
# Build against the committed .sqlx query cache; no database at build time.
ENV SQLX_OFFLINE=true
WORKDIR /build
# jemalloc fixes its page size at build time and refuses a kernel with bigger pages, so arm64 (16K/64K kernels exist) builds for 64K.
RUN if [ "$(uname -m)" = aarch64 ]; then lg_page=16; else lg_page=12; fi \
    && echo "export JEMALLOC_SYS_WITH_LG_PAGE=${lg_page}" > /jemalloc.env

# Manifests and empty sources only, so this stage rebuilds when a dependency changes and not on every source edit.
FROM builder AS deps
COPY Cargo.toml Cargo.lock rust-toolchain.toml ./
COPY .cargo .cargo
COPY crates/slimm-server/Cargo.toml crates/slimm-server/Cargo.toml
# One stub per target the manifest declares (lib, bin, bench); a new target or workspace member needs its stub here.
RUN mkdir -p crates/slimm-server/src crates/slimm-server/benches \
    && touch crates/slimm-server/src/lib.rs \
    && echo 'fn main() {}' | tee crates/slimm-server/src/main.rs > crates/slimm-server/benches/hot_paths.rs \
    && . /jemalloc.env \
    && cargo build --locked --release --bin slimm-server \
    && cargo clean --release --package slimm-server

FROM deps AS release
COPY crates/slimm-server/src crates/slimm-server/src
COPY crates/slimm-server/migrations crates/slimm-server/migrations
COPY .sqlx .sqlx
# Reported by /version; empty leaves the field off. Declared late so it only busts the build layer.
ARG SLIMM_BUILD_ID=
RUN . /jemalloc.env \
    && cargo build --locked --release --bin slimm-server \
    && mkdir -p /out/data \
    && cp target/release/slimm-server /out/slimm-server

FROM gcr.io/distroless/static-debian12:nonroot@sha256:1b7b9f0f0e0a1d2155f531db587cc48ec26aaf97ab64364225f5bf18a054e66a
COPY --from=release /out/slimm-server /usr/local/bin/slimm-server
COPY --from=release --chown=nonroot:nonroot /out/data /data

ENV SLIMM_PORT=8080 \
    SLIMM_DATABASE_PATH=/data/slimm.db \
    SLIMM_ATTACHMENTS_DIR=/data/media
EXPOSE 8080
VOLUME ["/data"]
USER nonroot

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["/usr/local/bin/slimm-server", "--healthcheck"]

ENTRYPOINT ["/usr/local/bin/slimm-server"]
