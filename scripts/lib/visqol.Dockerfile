# ViSQOL (google/visqol) built with bazel, for voice_quality_mos.py. About four minutes with 3 jobs.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates curl build-essential python3 python3-numpy python3-dev zip unzip && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /usr/local/bin/bazelisk https://github.com/bazelbuild/bazelisk/releases/download/v1.19.0/bazelisk-linux-amd64 && chmod +x /usr/local/bin/bazelisk && ln -s /usr/local/bin/bazelisk /usr/local/bin/bazel
RUN git clone https://github.com/google/visqol.git /visqol && git -C /visqol checkout 38d0b0163e441047d4429bf07ad09e5b9031d02c
WORKDIR /visqol
RUN USE_BAZEL_VERSION=$(cat .bazelversion) bazel build :visqol -c opt --jobs=3
