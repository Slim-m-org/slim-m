# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Places the reference scene through the real canvas op API."""
import json
import sys
import urllib.parse

import canvas_align_manifest as scene
from e2e_api import Api
from uuid7 import uuid7


def _channel(api, wanted):
    for channel in api.channels():
        if wanted in (channel["id"], channel["name"]):
            return channel
    sys.exit(f"no channel named or numbered {wanted!r} is visible to this account")


def seed(base_url, username, password, channel, allow_existing=False):
    """Uploads the reference image and places the four objects; returns the manifest."""
    api = Api(base_url)
    api.login(username, password, device="canvas-align")
    found = _channel(api, channel)
    channel_id = found["id"]
    if not allow_existing and api.canvas_objects(channel_id):
        sys.exit("that canvas already holds objects; use an empty channel (or --allow-existing)")
    name = urllib.parse.quote("canvas-align.png")
    attachment = api.call("POST", f"/attachments?filename={name}",
                          raw=scene.reference_png(), content_type="image/png")
    placed = [api.call("POST", f"/channels/{channel_id}/canvas/objects", placement)
              for placement in scene.placements(attachment, uuid7)]
    return scene.build_manifest(base_url, found, placed)


def write_manifest(manifest, path):
    with open(path, "w", encoding="utf-8") as out:
        json.dump(manifest, out, indent=2)
        out.write("\n")
