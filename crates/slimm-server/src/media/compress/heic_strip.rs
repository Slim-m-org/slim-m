// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Removes the location from a HEIC at the container level.
//!
//! The EXIF and XMP items are overwritten where they sit, so the file keeps its
//! length and every offset in `iloc` stays true; no pixel is decoded.

use super::Metadata;
use super::container_strip::{cleaned_exif, exif_needs_work};
use super::exif;

const HEADER: usize = 8;

/// The file with its EXIF rebuilt without a position and its XMP blanked, or `None` when it holds neither to change.
pub fn strip(bytes: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    if policy == Metadata::Keep {
        return None;
    }
    let items = metadata_items(bytes)?;
    let mut out = bytes.to_vec();
    let mut changed = false;
    for item in items {
        let Some(payload) = bytes.get(item.start..item.end) else {
            continue;
        };
        let replacement = match item.kind {
            ItemKind::Exif => exif_needs_work(payload, policy)
                .then(|| rebuilt_exif(payload, policy))
                .flatten(),
            ItemKind::Xmp => Some(vec![b' '; payload.len()]),
        };
        if let Some(replacement) = replacement.filter(|r| r != payload) {
            out[item.start..item.end].copy_from_slice(&replacement);
            changed = true;
        }
    }
    changed.then_some(out)
}

/// The item payload with its TIFF block replaced and zero-padded to the old length.
fn rebuilt_exif(payload: &[u8], policy: Metadata) -> Option<Vec<u8>> {
    let tiff_at = payload.len() - exif::tiff_block(payload).len();
    if tiff_at == payload.len() {
        return Some(vec![0; payload.len()]);
    }
    let block = cleaned_exif(payload, policy).unwrap_or_else(|| exif::orientation_only(1));
    let room = payload.len() - tiff_at;
    if block.len() > room {
        return Some(vec![0; payload.len()]);
    }
    let mut out = payload[..tiff_at].to_vec();
    out.extend_from_slice(&block);
    out.resize(payload.len(), 0);
    Some(out)
}

#[derive(Clone, Copy, PartialEq)]
enum ItemKind {
    Exif,
    Xmp,
}

struct Item {
    kind: ItemKind,
    start: usize,
    end: usize,
}

struct Cursor<'a> {
    data: &'a [u8],
    at: usize,
}

impl<'a> Cursor<'a> {
    fn take(&mut self, len: usize) -> Option<&'a [u8]> {
        let out = self.data.get(self.at..self.at.checked_add(len)?)?;
        self.at += len;
        Some(out)
    }

    fn uint(&mut self, len: usize) -> Option<u64> {
        let bytes = self.take(len)?;
        Some(bytes.iter().fold(0, |acc, b| (acc << 8) | u64::from(*b)))
    }
}

/// The payload ranges of every EXIF and XMP item that sits in the file body.
fn metadata_items(bytes: &[u8]) -> Option<Vec<Item>> {
    let meta = child(bytes, b"meta")?.get(4..)?;
    let kinds = item_kinds(child(meta, b"iinf")?)?;
    let located = item_locations(child(meta, b"iloc")?)?;
    Some(
        located
            .into_iter()
            .filter_map(|(id, start, end)| {
                let kind = kinds.iter().find(|(known, _)| *known == id)?.1;
                Some(Item { kind, start, end })
            })
            .collect(),
    )
}

/// The body of the first box called `name` in a run of boxes.
fn child<'a>(mut data: &'a [u8], name: &[u8; 4]) -> Option<&'a [u8]> {
    while data.len() >= HEADER {
        let size = u32::from_be_bytes(data[..4].try_into().ok()?) as usize;
        let size = if size == 0 { data.len() } else { size };
        let body = data.get(HEADER..size)?;
        if &data[4..8] == name {
            return Some(body);
        }
        data = data.get(size..)?;
    }
    None
}

/// Item ids and what they hold, for the items that can carry a location.
fn item_kinds(iinf: &[u8]) -> Option<Vec<(u32, ItemKind)>> {
    let version = *iinf.first()?;
    let skip = if version == 0 { 6 } else { 8 };
    let mut rest = iinf.get(skip..)?;
    let mut kinds = Vec::new();
    while rest.len() >= HEADER {
        let size = u32::from_be_bytes(rest[..4].try_into().ok()?) as usize;
        let body = rest.get(HEADER..size)?;
        if &rest[4..8] == b"infe" {
            kinds.extend(infe_kind(body));
        }
        rest = rest.get(size..)?;
    }
    Some(kinds)
}

fn infe_kind(body: &[u8]) -> Option<(u32, ItemKind)> {
    let version = *body.first()?;
    if version < 2 {
        return None;
    }
    let mut cursor = Cursor { data: body, at: 4 };
    let id = cursor.uint(if version == 2 { 2 } else { 4 })? as u32;
    cursor.take(2)?;
    let kind = cursor.take(4)?;
    if kind == b"Exif" {
        return Some((id, ItemKind::Exif));
    }
    let rest = body.get(cursor.at..)?;
    let mut strings = rest.split(|b| *b == 0).skip(1);
    let content_type = strings.next()?;
    (kind == b"mime" && content_type == b"application/rdf+xml").then_some((id, ItemKind::Xmp))
}

/// Item ids with the file range of their data, for single-extent items stored in the file body.
fn item_locations(iloc: &[u8]) -> Option<Vec<(u32, usize, usize)>> {
    let version = *iloc.first()?;
    if version > 2 {
        return None;
    }
    let mut cursor = Cursor { data: iloc, at: 4 };
    let sizes = cursor.uint(2)?;
    let (offset_size, length_size) = (
        ((sizes >> 12) & 0xF) as usize,
        ((sizes >> 8) & 0xF) as usize,
    );
    let (base_size, index_size) = (((sizes >> 4) & 0xF) as usize, (sizes & 0xF) as usize);
    let count = cursor.uint(if version < 2 { 2 } else { 4 })?;
    let mut out = Vec::new();
    for _ in 0..count {
        let id = cursor.uint(if version < 2 { 2 } else { 4 })? as u32;
        let in_file = version == 0 || cursor.uint(2)? & 0xF == 0;
        cursor.take(2)?;
        let base = cursor.uint(base_size)?;
        let extents = cursor.uint(2)?;
        let mut first = None;
        for _ in 0..extents {
            if version >= 1 {
                cursor.take(index_size)?;
            }
            let offset = cursor.uint(offset_size)?;
            let length = cursor.uint(length_size)?;
            first.get_or_insert((offset, length));
        }
        if let (true, 1, Some((offset, length))) = (in_file, extents, first) {
            let start = usize::try_from(base.checked_add(offset)?).ok()?;
            out.push((id, start, start.checked_add(usize::try_from(length).ok()?)?));
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SOURCE: &[u8] = include_bytes!("../../../tests/fixtures/tiny_gps.heic");
    const GPS: [u8; 24] = [
        52, 0, 0, 0, 1, 0, 0, 0, 31, 0, 0, 0, 1, 0, 0, 0, 12, 0, 0, 0, 1, 0, 0, 0,
    ];

    fn has(haystack: &[u8], needle: &[u8]) -> bool {
        haystack.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn the_position_and_the_xmp_are_removed_and_the_length_is_kept() {
        let out = strip(SOURCE, Metadata::RemoveLocation).unwrap();
        assert_eq!(out.len(), SOURCE.len());
        assert!(!has(&out, &GPS));
        assert!(!has(&out, b"GPSLatitude"));
        assert_eq!(out[..320], SOURCE[..320], "the boxes before the data stay");
    }

    #[test]
    fn the_pixel_data_is_not_touched() {
        let out = strip(SOURCE, Metadata::RemoveAll).unwrap();
        assert_eq!(out[328..328 + 0x669], SOURCE[328..328 + 0x669]);
    }

    #[test]
    fn keeping_all_metadata_changes_nothing() {
        assert!(strip(SOURCE, Metadata::Keep).is_none());
    }

    #[test]
    fn a_file_with_nothing_to_remove_is_left_as_it_is() {
        let clean = strip(SOURCE, Metadata::RemoveLocation).unwrap();
        assert!(strip(&clean, Metadata::RemoveLocation).is_none());
    }

    #[test]
    fn a_heic_with_no_metadata_items_is_left_as_it_is() {
        let plain = include_bytes!("../../../tests/fixtures/tiny.heic");
        assert!(strip(plain, Metadata::RemoveAll).is_none());
    }

    #[test]
    fn a_truncated_file_does_not_panic() {
        for len in (0..SOURCE.len()).step_by(7) {
            let _ = strip(&SOURCE[..len], Metadata::RemoveAll);
        }
    }
}
