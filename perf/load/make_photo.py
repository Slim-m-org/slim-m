# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
"""Writes a photo-like JPEG (smooth scene plus sensor noise) for the routes scenario; needs numpy and Pillow.

usage: make_photo.py OUT WIDTH HEIGHT [QUALITY]
"""
import sys
import numpy as np
from PIL import Image, ImageFilter

out, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
quality = int(sys.argv[4]) if len(sys.argv) > 4 else 95
rng = np.random.default_rng(7)
base = rng.integers(0, 256, size=(h // 100, w // 100, 3), dtype=np.uint8)
scene = Image.fromarray(base).resize((w, h), Image.BICUBIC).filter(ImageFilter.GaussianBlur(40))
arr = np.asarray(scene).astype(np.int16)
noise = rng.normal(0, 9, size=arr.shape).astype(np.int16)
Image.fromarray(np.clip(arr + noise, 0, 255).astype(np.uint8)).save(out, "JPEG", quality=quality, subsampling=2)
