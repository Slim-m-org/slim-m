# Photo compression on upload

Decision record and measurements for the space setting that shrinks photos when they are uploaded (`/space/media-compression`).
The owner's brief: a phone sends a raw 40 MB photo and it is stored at a reasonable size and format without a noticeable difference, toggleable, on listed types only, with an option to keep the original.

## What it does

- Off by default, so an upgrade changes nothing.
- The file type is decided by sniffing the bytes.
  The admin's extension list only chooses which sniffed formats are eligible: jpg/jpeg/jpe/jfif, png, webp, heic/heif/hif, bmp and tif/tiff.
  Defaults are jpg, jpeg, heic, heif, png, webp, bmp, tiff.
- A photograph becomes a progressive JPEG, 4:2:0, quality 90, MS-SSIM quantisation tables, longest side capped at 4096 px, upright, ICC profile kept.
- A screenshot, drawing or picture with transparency stays pixel-identical and only goes through oxipng (lossless).
  "Drawn" means more than 60% of pixels equal their left neighbour, or fewer than 2048 distinct colours.
- Animated PNG, animated WebP, multi-page TIFF, GIF, video and everything else are never touched.
- A result must be at least 10% smaller than the upload, or smaller at all when it keeps the format losslessly.
  HEIC, BMP and TIFF are always converted when they decode, because no client draws them.
  A JPEG that does not shrink but carries metadata the policy removes is rewritten at segment level, with no re-encode.
- Metadata: keep all, remove location (default), remove all.
  Orientation is always baked into the pixels, so the stored EXIF orientation is 1.
  Remove location rebuilds the EXIF block without GPS, thumbnail, maker note and embedded XMP/IPTC; remove all writes none.
  The metadata mode only applies while compression is on: stripping rewrites the file, and applying it with the switch off would change what an upgrade stores.
- Keep original stores the upload beside the copy as `<id>.orig`, served only at `GET /attachments/{id}?original=true` as a download.
  The quota and the storage screen count both files.

## Measurements

Reference for every row is the source decoded and resampled to the output size by Pillow (Lanczos), so only encoding loss is measured.
SSIMULACRA2 (higher is better; 90 is visually lossless, 70 is high quality) and a 7x7 luma SSIM.
Photos: Fronalpstock (10109x4542, 14.7 MB, scenery), Eiffel (2900x5367, 5.3 MB), phone12 (4032x3024 with sensor noise, EXIF orientation 6 and GPS, 4.2 MB).
At 100% a side-by-side crop of Eiffel at q90 against the reference could not be told apart.

Quality and tables at a 4096 px cap, 4:2:0:

| photo | setting | size | SSIMULACRA2 | SSIM |
|---|---|---|---|---|
| Fronalpstock | q85 standard | 1.40 MB | 78.7 | 0.9705 |
| Fronalpstock | q85 MS-SSIM | 1.37 MB | 79.3 | 0.9689 |
| Fronalpstock | q90 MS-SSIM | 1.76 MB | 82.8 | 0.9777 |
| Eiffel | q85 standard | 1.48 MB | 76.1 | 0.9767 |
| Eiffel | q85 MS-SSIM | 1.41 MB | 76.0 | 0.9766 |
| Eiffel | q90 MS-SSIM | 1.82 MB (34%) | about 81 | 0.983 |
| phone12 | q85 standard | 2.31 MB | 80.6 | 0.9598 |
| phone12 | q90 MS-SSIM | about 3.0 MB | about 86 | 0.984 |

4:4:4 at q85 costs about 25% more bytes for 3 to 4 points of SSIMULACRA2, about what q90 buys in 4:2:0, so 4:2:0 was kept.
MS-SSIM tables are 3 to 5% smaller than the standard ones at equal or better score.

Long-edge cap at q90, 4:2:0, MS-SSIM:

| source | 2560 | 3072 | 4096 |
|---|---|---|---|
| 108 MP phone, 58.8 MB | 1.20 MB | 1.68 MB | 2.84 MB |
| 83 MP painting, 94.3 MB | 1.73 MB | 2.54 MB | 4.55 MB |
| Fronalpstock, 14.7 MB | 0.76 MB | 1.05 MB | 1.76 MB |

SSIMULACRA2 stayed between 79 and 84 at every cap.
4096 was chosen so a 12 MP phone photo keeps its pixels; a 40 to 60 MB photo lands at 2 to 5 MB.

Lossless PNG (oxipng preset 2, pixel-identical in every case, checked by decoding both):

| input | before | after |
|---|---|---|
| UI screenshots 1280x800 | 128 to 424 KB | 74 to 95% of that |
| 16-bit RGBA UI screenshot | 700 KB | 87% |
| code screenshot 2560x1440 | 254 KB | 76% |
| transparent 1600x900 | 53 KB | 82% |
| photo saved as PNG, 4000x3000 | 14.2 MB | 2.37 MB as JPEG |

The `png` crate alone made screenshots larger than the input; oxipng's palette and filter search is what saves bytes.
A smooth, denoised phone photo (the pug HEIC) has 45% equal neighbours, which is why the drawn threshold is 60% and not lower.

## Memory

Prod runs the server in a 512 MiB container (slim-beta 256 MiB), idle about 40 MB resident.
Compression and preview decoding therefore draw from one memory budget (`media/memory_budget.rs`).

- The budget is the cgroup memory limit (the memory guard's resolver) minus headroom of max(96 MiB, a quarter of the limit): 384 MiB at 512 MiB, 160 MiB at 256 MiB, 1 GiB when no limit is found.
- A job reserves its estimated peak in 1 MiB units before it reads the file.
  The size comes from the file header (first 1 MiB), so nothing is read before admission; a file whose header cannot be read reserves its own size first and the rest once it is known.
- A job larger than the whole budget is stored as sent at once.
  Others wait in order for up to 30 s, then are stored as sent.
  A preview with no room is answered with the original.
- Estimate: source bytes + decoded pixels x 5 (JPEG, PNG and the rest x 8, HEIC x 7) + resized pixels x 4 + 24 MiB.
  Measured peaks sat under the estimate in every case (12 MP: 130 MB over idle against 138; 50 MP: 300 against 342; 108 MP at 1/2 scale: 290 against 270 after rounding, see the table).
- A JPEG whose long edge is at least twice the cap is decoded at a 1/2, 1/4 or 1/8 DCT scale (`jpeg-decoder`), so a 108 MP photo decodes to 27 MP, not 108.
  That took the 108 MP peak from 520 MB (and an OOM kill under `--memory=512m`) to about 290 MB over idle, and the time from 3.3 s to 1.2 s.
- Order on upload: compress, then derive previews from the stored (compressed) file.

Shipped musl image, `docker run --memory=512m --memory-swap=512m` (no swap, so an overrun would be a kill), one upload to a fresh container, compress and preview prewarm both running, `/healthz` polled every 50 ms.
`anon` is the process's own memory (the figure that matters); `peak` is the cgroup's, which also counts reclaimable file cache from the uploaded bytes.

| case | anon peak | cgroup peak | time | max /healthz | OOM |
|---|---|---|---|---|---|
| 12 MP JPEG, one | 170 MB | 183 MB | 0.6 s | 1 ms | no |
| 50 MP JPEG, one | 341 MB | 353 MB | 1.3 s | 1 ms | no |
| 108 MP JPEG, one | 328 MB | 397 MB | 1.2 s | 1 ms | no |
| 48 MP HEIC, one | stored as sent | 66 MB | 0.03 s | 1 ms | no |
| 12 MP JPEG, four at once | 402 MB | 425 MB | 1.1 s | 1 ms | no |
| 50 MP JPEG, four at once | 339 MB | 422 MB | 5.1 s | 2 ms | no |
| 108 MP JPEG, four at once | 338 MB | 537 MB | 4.4 s | 1 ms | no |
| 48 MP HEIC, four at once | stored as sent | 174 MB | 0.04 s | 1 ms | no |

Before this change the same 108 MP upload was OOM-killed at 512 MiB.
A 48 MP HEIC needs about 350 MB, so its estimate (421 MB) does not fit the 384 MiB budget and it is stored as sent; a 12 to 24 MP HEIC fits.
Four 108 MP photos run one at a time, so the fourth finishes at 4.4 s.
Outside the container, with the HEIC budget lifted, a 48 MP HEIC compresses in 1.1 s at an anon peak of about 290 MB.

## Time

| build | 12 MP | 108 MP |
|---|---|---|
| cargo release, opt-level 3 | 0.18 s | 0.8 s |
| release profile (opt-level z, lto), full decode | 0.5 s | 3.3 s |
| shipped musl image, scaled decode | 0.55 s | 1.2 s |

Pictures over 160 MP or files over 256 MB are stored as sent.
The default upload limit is 1 GiB (`SLIMM_ATTACHMENT_MAX_BYTES`), so a 40 MB photo passes it with room to spare.

## Formats and dependencies

- HEIC decodes with `zune-heic` (MIT/Apache-2.0/Zlib), pure safe Rust, no libheif.
  The `heic` crate was rejected: AGPL.
  It handled a 4032x3024 iPhone file in 53 ms and a hand-built HEVC still; a libheif sample with an unusual `mdat` layout failed to decode and is stored as sent.
  HEIC with alpha or 10-bit samples that the decoder refuses are also stored as sent.
- JPEG encode is `jpeg-encoder`, scaled JPEG decode is `jpeg-decoder`, resize is `fast_image_resize`, all pure Rust.
- `oxipng` brings `libdeflater`, a small C library compiled by the `cc` crate.
  `docker build -f docker/server.Dockerfile` builds it on the Alpine musl builder without changes.
- Not preserved on re-encode: HDR gain maps and multi-picture data (Ultra HDR), and the EXIF thumbnail.
  Keep original retains them.

## Preview memory for large photos and GIFs

Previews are derived from the stored file at upload, behind the same memory budget.
A baseline JPEG above 40 MP (up to 160 MP) is decoded at a 1/2, 1/4 or 1/8 DCT scale (`jpeg-decoder`), enough to keep the 1280 bucket sharp, so a 48 MP or 108 MP photo gets real previews; before, `?w=` returned the 34 MB original.
A progressive JPEG that large, or any other format past 40 MP, is still served as the original, since its coefficients or raster cannot fit.
A GIF, and an animated WebP or PNG, gets its first frame as a still at each bucket (`?w=` for a GIF, `?w=&still=true` for the others); the decode reads one frame, not the animation.

Shipped musl image, `docker run --memory=512m --memory-swap=512m`, compression off, one or four uploads at once to a fresh container, all three buckets then requested, `/healthz` polled every 30 ms.
`anon` is the process's own memory above its 30 MB idle; `peak` is the cgroup's, which also counts file cache from the uploaded bytes.
Time runs from the first upload to the last preview served.

| case | anon over idle | cgroup peak | time | max /healthz | OOM |
|---|---|---|---|---|---|
| 48 MP JPEG (34 MB), one | 57 MB | 152 MB | 0.7 s | 1 ms | no |
| 108 MP JPEG (19 MB), one | 50 MB | 112 MB | 0.5 s | 1 ms | no |
| GIF 1280x720, 30 frames (38 MB), one | 63 MB | 144 MB | 0.3 s | 1 ms | no |
| 48 MP JPEG, four at once | 71 MB | 250 MB | 2.5 s | 8 ms | no |
| 108 MP JPEG, four at once | 86 MB | 199 MB | 1.9 s | 6 ms | no |
| GIF, four at once | 143 MB | 341 MB | 0.6 s | 5 ms | no |

The 48 MP preview buckets came out at 27 KB, 71 KB and 182 KB (the 108 MP photo alike), against the 34 MB original.
The GIF stills were 18 KB, 97 KB and 507 KB for a 38 MB file.
The 108 MP file here was upscaled from the 48 MP one, so it is smaller on disk than a phone original; the decode cost follows pixels, not bytes.
