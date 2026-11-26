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

# Text to speech (decision 0142) is optional: PIPER_MODEL= (empty) leaves it off, and a voice that cannot be fetched does not stop the listener.
fetch_voice() {
    url=$1 dest=$2 want=$3
    [ -f "$dest" ] && return 0
    tmp="$dest.part"
    curl -fsSL --retry 3 -o "$tmp" "$url" || return 1
    [ "$(sha256sum "$tmp" | cut -d' ' -f1)" = "$want" ] || { rm -f "$tmp"; return 1; }
    mv "$tmp" "$dest"
}

if [ -n "${PIPER_MODEL:-}" ]; then
    echo "fetching the text to speech voice once from $PIPER_MODEL_URL"
    if ! fetch_voice "$PIPER_MODEL_URL" "$PIPER_MODEL" "$PIPER_MODEL_SHA256" \
        || ! fetch_voice "$PIPER_CONFIG_URL" "$PIPER_MODEL.json" "$PIPER_CONFIG_SHA256"; then
        echo "the voice could not be fetched or did not match its pinned sha256; text to speech stays off" >&2
        unset PIPER_MODEL
    fi
fi

exec /usr/local/bin/slimm-listener
