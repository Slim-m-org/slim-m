# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The optional call-audio listener (decision 0104). Debian rather than the
# server's static musl image: libwebrtc ships prebuilt for glibc only. Runs as
# a non-root user with a read-only root; the only writable place is /models,
# where the speech model is downloaded once and checked against a pinned sha256.

FROM rust:1.97.1-bookworm@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97 AS builder
# libwebrtc's build needs clang 21, newer than the base image's, so it comes from LLVM's own signed apt repository.
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake pkg-config libssl-dev gnupg \
    && curl -fsSL https://apt.llvm.org/llvm-snapshot.gpg.key | gpg --dearmor -o /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-21 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends clang-21 libclang-21-dev \
    && rm -rf /var/lib/apt/lists/*
ENV CC=clang-21 CXX=clang++-21 LIBCLANG_PATH=/usr/lib/llvm-21/lib
WORKDIR /build
COPY crates/slimm-listener/ .
RUN cargo build --locked --release --bin slimm-listener

FROM debian:bookworm-slim@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libssl3 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home listener \
    && mkdir /models && chown listener /models
COPY --from=builder /build/target/release/slimm-listener /usr/local/bin/slimm-listener
COPY docker/listener-entrypoint.sh /usr/local/bin/listener-entrypoint
# Pinned to a commit of the model repository, so a moved tag cannot change what is fetched.
ENV WHISPER_MODEL=/models/ggml-base.bin \
    WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin \
    WHISPER_MODEL_SHA256=60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe \
    LISTENER_ADDR=0.0.0.0:9400
EXPOSE 9400
VOLUME ["/models"]
USER listener
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD ["curl", "-fsS", "http://127.0.0.1:9400/healthz"]
ENTRYPOINT ["/usr/local/bin/listener-entrypoint"]
