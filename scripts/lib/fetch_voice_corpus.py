# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Builds the voice harness corpus from voice_corpus_manifest.json; no audio lives in the repo.

usage: fetch_voice_corpus.py [--out DIR] [--only id,id] [--record]

Sources are downloaded once into DIR/../cache and checked against the manifest's
sha256 (a mismatch is an error: the upstream file changed). Each clip is cut,
resampled to 48 kHz mono with ffmpeg, mixed and levelled by voice_corpus.py.
Output hashes differ across ffmpeg builds, so a changed one only warns.
--record fills in source hashes, output hashes and durations after a fresh build.
The default DIR is ~/.slimm-scratch/tmp/voice-corpus/clips; point E2E_VQ_CORPUS at it.
"""
import array
import hashlib
import io
import json
import os
import subprocess
import sys
import time
import urllib.request
import zipfile

import voice_corpus as corpus
import voice_quality_dsp as dsp

AGENT = "slimm-voice-corpus/1.0 (https://github.com/Slim-m-org)"
DEFAULT_OUT = os.path.expanduser("~/.slimm-scratch/tmp/voice-corpus/clips")
TRIES = 6


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


class RangeFile(io.RawIOBase):
    """A read-only seekable view of an HTTP file that honours Range requests."""

    def __init__(self, url):
        self.pos = 0
        self.size, self.url = _retry(lambda: self._probe(url))

    @staticmethod
    def _probe(url):
        probe = urllib.request.Request(url, headers={"Range": "bytes=0-0", "User-Agent": AGENT})
        with urllib.request.urlopen(probe, timeout=60) as resp:
            return int(resp.headers["Content-Range"].split("/")[1]), resp.geturl()

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        base = (0, self.pos, self.size)[whence]
        self.pos = base + offset
        return self.pos

    def read(self, count=-1):
        if count < 0 or self.pos + count > self.size:
            count = self.size - self.pos
        if count <= 0:
            return b""
        req = urllib.request.Request(self.url, headers={
            "Range": f"bytes={self.pos}-{self.pos + count - 1}", "User-Agent": AGENT})
        data = _retry(lambda: urllib.request.urlopen(req, timeout=120).read())
        self.pos += len(data)
        return data

    def readinto(self, buffer):
        data = self.read(len(buffer))
        buffer[:len(data)] = data
        return len(data)


def _retry(action):
    for attempt in range(TRIES):
        try:
            return action()
        except (OSError, AttributeError):
            if attempt == TRIES - 1:
                raise
            time.sleep(3 * (attempt + 1))


class Fetcher:
    def __init__(self, cache):
        self.cache = cache
        self.zips = {}
        os.makedirs(cache, exist_ok=True)

    def _zip(self, url):
        if url not in self.zips:
            self.zips[url] = zipfile.ZipFile(io.BufferedReader(RangeFile(url), 1 << 20))
        return self.zips[url]

    def path(self, part):
        """The local file for a part, downloaded (and hash-checked) when missing."""
        key = part["url"] + "#" + part.get("member", "")
        name = hashlib.sha256(key.encode()).hexdigest()[:16] + "-" + os.path.basename(
            part.get("member") or part["url"].split("?")[0])
        path = os.path.join(self.cache, name)
        if not os.path.exists(path) or (part.get("sha256") and sha256_file(path) != part["sha256"]):
            self._download(part, path)
        return path

    def _download(self, part, path):
        for attempt in range(TRIES):
            if part.get("member"):
                data = self._zip(part["url"]).read(part["member"])
            else:
                req = urllib.request.Request(part["url"], headers={"User-Agent": AGENT})
                data = _retry(lambda: urllib.request.urlopen(req, timeout=180).read())
            with open(path, "wb") as fh:
                fh.write(data)
            if not part.get("sha256") or sha256_file(path) == part["sha256"]:
                time.sleep(1.5)
                return
            time.sleep(10 * (attempt + 1))
        raise SystemExit(f"{part['url']}: the file no longer matches the manifest sha256")


def decode(path, start_s, dur_s):
    """48 kHz mono samples of a slice of any file ffmpeg reads."""
    cut = ["-ss", str(start_s)] if start_s else []
    cut += ["-t", str(dur_s)] if dur_s else []
    raw = subprocess.run(["ffmpeg", "-v", "error", *cut, "-i", path, "-vn", "-ac", "1",
                          "-ar", str(corpus.RATE), "-f", "f32le", "-"],
                         capture_output=True, check=True).stdout
    return array.array("f", raw).tolist()


def build_layer(fetcher, layer):
    chunks = []
    for part in layer["parts"]:
        samples = decode(fetcher.path(part), part.get("start_s", 0), part.get("dur_s", 0))
        chunks += [samples] * part.get("repeat", 1)
    samples = corpus.concat(chunks, layer.get("gap_ms", 350) / 1000)
    if "level_dbfs" in layer:
        samples, _, _ = corpus.normalise(samples, layer["level_dbfs"])
    return samples, layer.get("offset_s", 0), layer.get("gain_db", 0)


def build_clip(fetcher, clip):
    mixed = corpus.mix([build_layer(fetcher, layer) for layer in clip["layers"]])
    return corpus.normalise(mixed, clip["level_dbfs"])


def record_sources(fetcher, clip):
    for layer in clip["layers"]:
        for part in layer["parts"]:
            part["sha256"] = sha256_file(fetcher.path(part))


def main(argv):
    out = argv[argv.index("--out") + 1] if "--out" in argv else DEFAULT_OUT
    only = argv[argv.index("--only") + 1].split(",") if "--only" in argv else None
    record = "--record" in argv
    manifest = corpus.load_manifest()
    fetcher = Fetcher(os.path.join(os.path.dirname(out.rstrip("/")), "cache"))
    os.makedirs(out, exist_ok=True)
    for clip in manifest["clips"]:
        if only and clip["id"] not in only:
            continue
        if record:
            record_sources(fetcher, clip)
        samples, gain, limited = build_clip(fetcher, clip)
        path = os.path.join(out, clip["id"] + ".wav")
        dsp.write_wav(path, samples, corpus.RATE)
        digest = sha256_file(path)
        if record:
            clip.update({"sha256": digest, "seconds": round(len(samples) / corpus.RATE, 2),
                         "gain_db": gain, "peak_limited": limited})
        elif clip.get("sha256") and clip["sha256"] != digest:
            print(f"warning: {clip['id']} differs from the manifest hash (ffmpeg build?)")
        print(f"{clip['id']:34} {len(samples) / corpus.RATE:6.1f}s gain {gain:+6.1f} dB"
              f"{' (peak limited)' if limited else ''}", flush=True)
    if record:
        with open(corpus.MANIFEST, "w", encoding="utf-8") as fh:
            json.dump(manifest, fh, indent=1, ensure_ascii=False)
            fh.write("\n")


if __name__ == "__main__":
    main(sys.argv)
