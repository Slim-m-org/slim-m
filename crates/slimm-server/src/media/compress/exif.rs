// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Just enough TIFF/EXIF reading and writing to keep, rebuild or drop a photo's
//! metadata without a general EXIF library.
//!
//! Rebuilding copies entries byte for byte in the source's own byte order and
//! lays out a fresh file, so a removed block (GPS, thumbnail, maker note) leaves
//! no bytes behind: nothing is "zeroed in place".

const TAG_ORIENTATION: u16 = 0x0112;
const TAG_EXIF_IFD: u16 = 0x8769;
const TAG_GPS_IFD: u16 = 0x8825;
const TAG_PIXEL_X: u16 = 0xA002;
const TAG_PIXEL_Y: u16 = 0xA003;
const TYPE_SHORT: u16 = 3;
const TYPE_LONG: u16 = 4;

/// IFD0 entries a rebuilt block never carries: location, embedded packets and sub-IFDs.
const DROP_IFD0: &[u16] = &[
    TAG_GPS_IFD,
    0x02BC,
    0x83BB,
    0x014A,
    0xC4A5,
    0x8649,
    0x8773,
    TAG_EXIF_IFD,
];
/// Exif sub-IFD entries a rebuilt block never carries: the maker note holds absolute offsets that a move breaks.
const DROP_EXIF: &[u16] = &[0x927C, 0xA005];

/// The TIFF block of an EXIF payload, past any `Exif\0\0` prefix or the
/// offset a HEIF item stores in front of it.
pub fn tiff_block(raw: &[u8]) -> &[u8] {
    let head = &raw[..raw.len().min(16)];
    let start = head
        .windows(4)
        .position(|w| w == b"II*\0" || w == b"MM\0*")
        .unwrap_or(0);
    &raw[start..]
}

#[derive(Clone, Copy)]
struct Tiff<'a> {
    data: &'a [u8],
    little: bool,
}

#[derive(Clone, Copy)]
struct Entry {
    tag: u16,
    kind: u16,
    count: u32,
    field: [u8; 4],
}

impl<'a> Tiff<'a> {
    fn parse(data: &'a [u8]) -> Option<Self> {
        let little = match data.get(..2)? {
            b"II" => true,
            b"MM" => false,
            _ => return None,
        };
        let tiff = Self { data, little };
        (tiff.u16(2)? == 42).then_some(tiff)
    }

    fn u16(&self, at: usize) -> Option<u16> {
        let b: [u8; 2] = self.data.get(at..at + 2)?.try_into().ok()?;
        Some(if self.little {
            u16::from_le_bytes(b)
        } else {
            u16::from_be_bytes(b)
        })
    }

    fn u32(&self, at: usize) -> Option<u32> {
        let b: [u8; 4] = self.data.get(at..at + 4)?.try_into().ok()?;
        Some(if self.little {
            u32::from_le_bytes(b)
        } else {
            u32::from_be_bytes(b)
        })
    }

    fn put16(&self, v: u16) -> [u8; 2] {
        if self.little {
            v.to_le_bytes()
        } else {
            v.to_be_bytes()
        }
    }

    fn put32(&self, v: u32) -> [u8; 4] {
        if self.little {
            v.to_le_bytes()
        } else {
            v.to_be_bytes()
        }
    }

    fn ifd0(&self) -> Option<usize> {
        self.u32(4).map(|o| o as usize)
    }

    fn entries(&self, ifd: usize) -> Option<Vec<Entry>> {
        let n = self.u16(ifd)? as usize;
        if n > 512 {
            return None;
        }
        (0..n)
            .map(|i| {
                let at = ifd + 2 + i * 12;
                Some(Entry {
                    tag: self.u16(at)?,
                    kind: self.u16(at + 2)?,
                    count: self.u32(at + 4)?,
                    field: self.data.get(at + 8..at + 12)?.try_into().ok()?,
                })
            })
            .collect()
    }

    fn value_len(entry: &Entry) -> Option<usize> {
        let unit = match entry.kind {
            1 | 2 | 6 | 7 => 1,
            3 | 8 => 2,
            4 | 9 | 11 | 13 => 4,
            5 | 10 | 12 => 8,
            _ => return None,
        };
        (entry.count as usize).checked_mul(unit)
    }

    fn value_bytes(&self, entry: &Entry) -> Option<Vec<u8>> {
        let len = Self::value_len(entry)?;
        if len <= 4 {
            return Some(entry.field[..len].to_vec());
        }
        let off = self.u32_of(&entry.field) as usize;
        self.data
            .get(off..off.checked_add(len)?)
            .map(<[u8]>::to_vec)
    }

    fn u32_of(&self, b: &[u8; 4]) -> u32 {
        if self.little {
            u32::from_le_bytes(*b)
        } else {
            u32::from_be_bytes(*b)
        }
    }
}

/// The orientation tag (1 to 8) of an EXIF payload, if it has one.
pub fn orientation(raw: &[u8]) -> Option<u16> {
    let tiff = Tiff::parse(tiff_block(raw))?;
    let entry = tiff
        .entries(tiff.ifd0()?)?
        .into_iter()
        .find(|e| e.tag == TAG_ORIENTATION)?;
    let value = if tiff.little {
        u16::from_le_bytes([entry.field[0], entry.field[1]])
    } else {
        u16::from_be_bytes([entry.field[0], entry.field[1]])
    };
    (1..=8).contains(&value).then_some(value)
}

/// Whether the payload holds a GPS block.
pub fn has_location(raw: &[u8]) -> bool {
    let Some(tiff) = Tiff::parse(tiff_block(raw)) else {
        return false;
    };
    tiff.ifd0()
        .and_then(|ifd| tiff.entries(ifd))
        .is_some_and(|entries| entries.iter().any(|e| e.tag == TAG_GPS_IFD))
}

/// A block holding only an orientation, for a file whose pixels stay unrotated.
pub fn orientation_only(orientation: u16) -> Vec<u8> {
    let mut out = b"II\x2a\0\x08\0\0\0".to_vec();
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&TAG_ORIENTATION.to_le_bytes());
    out.extend_from_slice(&TYPE_SHORT.to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&orientation.to_le_bytes());
    out.extend_from_slice(&[0, 0]);
    out.extend_from_slice(&0u32.to_le_bytes());
    out
}

/// What a rewritten block says about the pixels it now describes.
#[derive(Clone, Copy)]
pub struct Rewrite {
    /// The orientation to record, or `None` to leave the source's.
    pub orientation: Option<u16>,
    /// The pixel size to record when the source stated one.
    pub dimensions: Option<(u32, u32)>,
}

/// The whole payload with the orientation and size fields updated in place, for
/// "keep all": every other byte stays, thumbnail and maker note included.
pub fn patched(raw: &[u8], rewrite: Rewrite) -> Vec<u8> {
    let mut out = tiff_block(raw).to_vec();
    let Some(tiff) = Tiff::parse(&out) else {
        return out;
    };
    let mut writes: Vec<(usize, Vec<u8>)> = Vec::new();
    let Some(ifd0) = tiff.ifd0() else { return out };
    let Some(entries) = tiff.entries(ifd0) else {
        return out;
    };
    for (i, e) in entries.iter().enumerate() {
        let field_at = ifd0 + 2 + i * 12 + 8;
        match (e.tag, rewrite.orientation) {
            (TAG_ORIENTATION, Some(o)) => writes.push((field_at, short_field(&tiff, o))),
            (TAG_EXIF_IFD, _) => {
                let sub = tiff.u32_of(&e.field) as usize;
                writes.extend(dimension_writes(&tiff, sub, rewrite.dimensions));
            }
            _ => {}
        }
    }
    for (at, bytes) in writes {
        out[at..at + bytes.len()].copy_from_slice(&bytes);
    }
    out
}

fn short_field(tiff: &Tiff, value: u16) -> Vec<u8> {
    let mut field = tiff.put16(value).to_vec();
    field.extend_from_slice(&[0, 0]);
    field
}

fn dimension_writes(
    tiff: &Tiff,
    exif_ifd: usize,
    dimensions: Option<(u32, u32)>,
) -> Vec<(usize, Vec<u8>)> {
    let Some((w, h)) = dimensions else {
        return Vec::new();
    };
    let Some(entries) = tiff.entries(exif_ifd) else {
        return Vec::new();
    };
    let mut writes = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        let value = match e.tag {
            TAG_PIXEL_X => w,
            TAG_PIXEL_Y => h,
            _ => continue,
        };
        let at = exif_ifd + 2 + i * 12 + 8;
        match e.kind {
            TYPE_SHORT if value <= u32::from(u16::MAX) => {
                writes.push((at, short_field(tiff, value as u16)));
            }
            TYPE_LONG => writes.push((at, tiff.put32(value).to_vec())),
            _ => {}
        }
    }
    writes
}

/// A fresh block with the camera and exposure fields but no GPS, thumbnail,
/// maker note or embedded packets. `None` when the source does not parse.
pub fn without_location(raw: &[u8], rewrite: Rewrite) -> Option<Vec<u8>> {
    let tiff = Tiff::parse(tiff_block(raw))?;
    let ifd0_entries = tiff.entries(tiff.ifd0()?)?;
    let exif_entries = ifd0_entries
        .iter()
        .find(|e| e.tag == TAG_EXIF_IFD)
        .and_then(|e| tiff.entries(tiff.u32_of(&e.field) as usize))
        .unwrap_or_default();
    let ifd0 = kept(&tiff, &ifd0_entries, DROP_IFD0, rewrite)?;
    let exif = kept(&tiff, &exif_entries, DROP_EXIF, rewrite)?;
    Some(layout(&tiff, ifd0, exif))
}

type Kept = Vec<(Entry, Option<Vec<u8>>)>;

fn kept(tiff: &Tiff, entries: &[Entry], drop: &[u16], rewrite: Rewrite) -> Option<Kept> {
    let mut out = Vec::new();
    for e in entries.iter().filter(|e| !drop.contains(&e.tag)) {
        let mut entry = *e;
        let wanted = match (e.tag, rewrite.orientation, rewrite.dimensions) {
            (TAG_ORIENTATION, Some(o), _) => Some(short_field(tiff, o)),
            (TAG_PIXEL_X, _, Some((w, _))) if e.kind == TYPE_LONG => Some(tiff.put32(w).to_vec()),
            (TAG_PIXEL_Y, _, Some((_, h))) if e.kind == TYPE_LONG => Some(tiff.put32(h).to_vec()),
            _ => None,
        };
        if let Some(field) = wanted {
            entry.field.copy_from_slice(&field);
            out.push((entry, None));
            continue;
        }
        let len = Tiff::value_len(e)?;
        let payload = if len > 4 {
            Some(tiff.value_bytes(e)?)
        } else {
            None
        };
        out.push((entry, payload));
    }
    Some(out)
}

fn layout(tiff: &Tiff, mut ifd0: Kept, mut exif: Kept) -> Vec<u8> {
    let has_exif = !exif.is_empty();
    let ifd0_len = 2 + (ifd0.len() + usize::from(has_exif)) * 12 + 4;
    let exif_len = if has_exif { 2 + exif.len() * 12 + 4 } else { 0 };
    let exif_at = 8 + ifd0_len;
    let data_start = exif_at + exif_len;
    let mut data: Vec<u8> = Vec::new();
    for (entry, payload) in ifd0.iter_mut().chain(exif.iter_mut()) {
        if let Some(bytes) = payload {
            entry.field = tiff.put32((data_start + data.len()) as u32);
            data.extend_from_slice(bytes);
            if data.len() % 2 == 1 {
                data.push(0);
            }
        }
    }
    if has_exif {
        ifd0.push((
            Entry {
                tag: TAG_EXIF_IFD,
                kind: TYPE_LONG,
                count: 1,
                field: tiff.put32(exif_at as u32),
            },
            None,
        ));
        ifd0.sort_by_key(|(e, _)| e.tag);
    }
    let mut out = Vec::with_capacity(data_start + data.len());
    out.extend_from_slice(if tiff.little { b"II" } else { b"MM" });
    out.extend_from_slice(&tiff.put16(42));
    out.extend_from_slice(&tiff.put32(8));
    write_ifd(tiff, &mut out, &ifd0);
    if has_exif {
        write_ifd(tiff, &mut out, &exif);
    }
    out.extend_from_slice(&data);
    out
}

fn write_ifd(tiff: &Tiff, out: &mut Vec<u8>, entries: &[(Entry, Option<Vec<u8>>)]) {
    out.extend_from_slice(&tiff.put16(entries.len() as u16));
    for (e, _) in entries {
        out.extend_from_slice(&tiff.put16(e.tag));
        out.extend_from_slice(&tiff.put16(e.kind));
        out.extend_from_slice(&tiff.put32(e.count));
        out.extend_from_slice(&e.field);
    }
    out.extend_from_slice(&[0, 0, 0, 0]);
}
