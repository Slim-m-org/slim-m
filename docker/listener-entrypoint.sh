#!/bin/sh
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
# Fetches the speech model once, checks it against a pinned sha256, then starts the listener.
# The download carries no audio. A file already at WHISPER_MODEL is used as it is.
set -eu

if [ ! -f "$WHISPER_MODEL" ]; then
    tmp="$WHISPER_MODEL.part"
    echo "downloading the speech model once from $WHISPER_MODEL_URL"
    curl -fsSL --retry 3 -o "$tmp" "$WHISPER_MODEL_URL"
    actual=$(sha256sum "$tmp" | cut -d' ' -f1)
    if [ "$actual" != "$WHISPER_MODEL_SHA256" ]; then
        rm -f "$tmp"
        echo "the downloaded model does not match the pinned sha256" >&2
        exit 1
    fi
    mv "$tmp" "$WHISPER_MODEL"
fi

exec /usr/local/bin/slimm-listener
