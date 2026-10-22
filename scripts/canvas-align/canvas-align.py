#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Measures how far canvas objects drift between screen sizes and clients.

    canvas-align.py seed --base-url URL --username U --channel NAME [--out manifest.json]
    canvas-align.py capture-web --base-url URL --web-url URL --username U --manifest manifest.json
    canvas-align.py measure --manifest manifest.json shot1.png shot2.png ...

See README.md. The password is read from CANVAS_ALIGN_PASSWORD.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lib"))

import canvas_align_capture as capture  # noqa: E402
import canvas_align_report as report  # noqa: E402
import canvas_align_seed as seeding  # noqa: E402
from canvas_align_geometry import TOLERANCE_PX  # noqa: E402


def _password():
    value = os.environ.get("CANVAS_ALIGN_PASSWORD")
    if not value:
        sys.exit("set CANVAS_ALIGN_PASSWORD to the account's password")
    return value


def _parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    steps = parser.add_subparsers(dest="step", required=True)

    seed = steps.add_parser("seed", help="place the reference scene and write the manifest")
    seed.add_argument("--base-url", required=True)
    seed.add_argument("--username", required=True)
    seed.add_argument("--channel", required=True, help="channel name or id")
    seed.add_argument("--out", default="canvas-align-manifest.json")
    seed.add_argument("--allow-existing", action="store_true",
                      help="place into a canvas that already holds objects")

    shoot = steps.add_parser("capture-web", help="screenshot the web client at five sizes")
    shoot.add_argument("--base-url", required=True)
    shoot.add_argument("--web-url", required=True, help="where the web client is served")
    shoot.add_argument("--username", required=True)
    shoot.add_argument("--manifest", required=True)
    shoot.add_argument("--out-dir", default="canvas-align-shots")
    shoot.add_argument("--tolerance", type=float, default=TOLERANCE_PX)
    shoot.add_argument("--no-measure", action="store_true")

    measure = steps.add_parser("measure", help="print each marker's offset in a screenshot")
    measure.add_argument("--manifest", required=True)
    measure.add_argument("--tolerance", type=float, default=TOLERANCE_PX)
    measure.add_argument("--annotate-dir", help="save diff images here")
    measure.add_argument("screenshots", nargs="+")
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    if args.step == "seed":
        manifest = seeding.seed(args.base_url, args.username, _password(), args.channel,
                                args.allow_existing)
        seeding.write_manifest(manifest, args.out)
        print(f"placed {len(manifest['objects'])} objects in {manifest['channel_id']}; "
              f"manifest written to {args.out}")
        return 0
    if args.step == "capture-web":
        paths = capture.capture_web(args, _password())
        if args.no_measure:
            return 0
        return report.run(paths, args.manifest, args.tolerance,
                          os.path.join(args.out_dir, "diff"))
    return report.run(args.screenshots, args.manifest, args.tolerance, args.annotate_dir)


if __name__ == "__main__":
    sys.exit(main())
