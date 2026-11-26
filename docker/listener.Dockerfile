# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# The optional call-audio listener (decision 0105). Debian rather than the
# server's static musl image: libwebrtc ships prebuilt for glibc only. Runs as
# a non-root user with a read-only root; the only writable place is /models,
# where the speech model is downloaded once and checked against a pinned sha256.

# rust 1.97.1 on bookworm, pinned by digest alone so the tag cannot disagree with it.
FROM rust@sha256:0e2bcaef56d041a486784e54104a81aebe0da44bd03019bd70bc0401e42e4a97 AS builder
# libwebrtc's build needs clang 21, newer than the base image's, so it comes from LLVM's own signed apt repository, whose key is checked against a pinned fingerprint.
COPY docker/listener-llvm-key.sh /usr/local/bin/listener-llvm-key
RUN apt-get update \
    && apt-get install -y --no-install-recommends cmake gnupg libglib2.0-dev libssl-dev pkg-config \
    && listener-llvm-key /usr/share/keyrings/llvm.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/llvm.gpg] https://apt.llvm.org/bookworm/ llvm-toolchain-bookworm-21 main" > /etc/apt/sources.list.d/llvm.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends clang-21 libclang-21-dev \
    && rm -rf /var/lib/apt/lists/*
ENV CC=clang-21 CXX=clang++-21 LIBCLANG_PATH=/usr/lib/llvm-21/lib
# A portable x86-64-v3 whisper.cpp, not one tuned to the build runner's CPU, which the host may lack (arm64 ignores the x86 flags).
ENV GGML_NATIVE=OFF GGML_AVX=ON GGML_AVX2=ON GGML_FMA=ON GGML_F16C=ON
WORKDIR /build
COPY crates/slimm-listener/ .
RUN cargo build --locked --release --bin slimm-listener

FROM debian@sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libssl3 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --uid 10001 --no-create-home listener \
    && mkdir /models && chown listener /models
# Piper's own release build (decision 0142), pinned by sha256 per architecture; it ships its phonemizer and espeak-ng data beside the binary.
ARG TARGETARCH
RUN case "$TARGETARCH" in \
      amd64) arch=x86_64; sum=a50cb45f355b7af1f6d758c1b360717877ba0a398cc8cbe6d2a7a3a26e225992 ;; \
      arm64) arch=aarch64; sum=fea0fd2d87c54dbc7078d0f878289f404bd4d6eea6e7444a77835d1537ab88eb ;; \
      *) echo "no Piper build for $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && curl -fsSL --retry 3 -o /tmp/piper.tar.gz "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_${arch}.tar.gz" \
    && echo "$sum  /tmp/piper.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/piper.tar.gz -C /opt \
    && rm /tmp/piper.tar.gz
COPY --from=builder /build/target/release/slimm-listener /usr/local/bin/slimm-listener
COPY docker/listener-entrypoint.sh /usr/local/bin/listener-entrypoint
# Pinned to a commit of the model repository, so a moved tag cannot change what is fetched.
ENV WHISPER_MODEL=/models/ggml-base.bin \
    WHISPER_MODEL_URL=https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin \
    WHISPER_MODEL_SHA256=60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe \
    LISTENER_ADDR=0.0.0.0:9400 \
    PIPER_BIN=/opt/piper/piper \
    PIPER_MODEL=/models/en_US-lessac-medium.onnx \
    PIPER_MODEL_URL=https://huggingface.co/rhasspy/piper-voices/resolve/5ec43b186ef915a195d3ddbcfd9916e76c503c3f/en/en_US/lessac/medium/en_US-lessac-medium.onnx \
    PIPER_MODEL_SHA256=5efe09e69902187827af646e1a6e9d269dee769f9877d17b16b1b46eeaaf019f \
    PIPER_CONFIG_URL=https://huggingface.co/rhasspy/piper-voices/resolve/5ec43b186ef915a195d3ddbcfd9916e76c503c3f/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json \
    PIPER_CONFIG_SHA256=efe19c417bed055f2d69908248c6ba650fa135bc868b0e6abb3da181dab690a0
EXPOSE 9400
VOLUME ["/models"]
USER listener
HEALTHCHECK --interval=30s --timeout=3s --start-period=60s --retries=3 \
    CMD ["curl", "-fsS", "http://127.0.0.1:9400/healthz"]
ENTRYPOINT ["/usr/local/bin/listener-entrypoint"]
