# ViSQOL (google/visqol) built with bazel, for voice_quality_mos.py. About four minutes with 3 jobs.
FROM ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb
ENV DEBIAN_FRONTEND=noninteractive
ADD --chmod=755 --checksum=sha256:d28b588ac0916abd6bf02defb5433f6eddf7cba35ffa808eabb65a44aab226f7 https://github.com/bazelbuild/bazelisk/releases/download/v1.19.0/bazelisk-linux-amd64 /usr/local/bin/bazelisk
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
        python3 \
        python3-dev \
        python3-numpy \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s /usr/local/bin/bazelisk /usr/local/bin/bazel \
    && useradd --create-home --uid 1000 visqol \
    && git clone https://github.com/google/visqol.git /visqol \
    && git -C /visqol checkout 38d0b0163e441047d4429bf07ad09e5b9031d02c \
    && chown -R visqol:visqol /visqol
USER visqol
WORKDIR /visqol
RUN USE_BAZEL_VERSION=$(cat .bazelversion) bazel build :visqol -c opt --jobs=3
