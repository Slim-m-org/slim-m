// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which stretches of which log files make up the newest `max_bytes` of log,
//! decided once from the sizes listed, so a file still growing while it is
//! read never makes a download longer than its plan.

use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use jiff::civil::Date;

use super::files::list;

/// How far past a cut a line break is looked for before the cut stays mid-line.
const LINE_SEARCH_BYTES: u64 = 64 * 1024;

/// One stretch of one log file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Segment {
    pub path: PathBuf,
    pub start: u64,
    pub len: u64,
}

/// The newest log, oldest stretch first.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct RecentPlan {
    pub segments: Vec<Segment>,
    /// Older lines exist that did not fit.
    pub truncated: bool,
}

/// Plans at most `max_bytes` of the newest log in `dir`, starting at a whole line.
/// A file dated after `today` is from a clock that ran ahead, and is left out.
pub fn plan_recent(dir: &Path, max_bytes: u64, today: Date) -> io::Result<RecentPlan> {
    let mut files = match list(dir) {
        Ok(files) => files,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(RecentPlan::default()),
        Err(error) => return Err(error),
    };
    files.retain(|f| f.day <= today);
    files.sort_by_key(|f| std::cmp::Reverse((f.day, f.index)));
    let mut plan = RecentPlan::default();
    let mut left = max_bytes;
    for file in files {
        if left == 0 {
            plan.truncated = true;
            break;
        }
        if file.bytes <= left {
            left -= file.bytes;
            plan.segments.push(Segment {
                path: file.path,
                start: 0,
                len: file.bytes,
            });
            continue;
        }
        let cut = file.bytes - left;
        let start = next_line(&file.path, cut)?.min(file.bytes);
        plan.segments.push(Segment {
            path: file.path,
            start,
            len: file.bytes - start,
        });
        plan.truncated = true;
        break;
    }
    plan.segments.reverse();
    Ok(plan)
}

/// The offset just past the first line break at or after `from`; `from` itself when none is near.
fn next_line(path: &Path, from: u64) -> io::Result<u64> {
    let mut file = match File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(from),
        Err(error) => return Err(error),
    };
    file.seek(SeekFrom::Start(from))?;
    let mut window = Vec::new();
    file.take(LINE_SEARCH_BYTES).read_to_end(&mut window)?;
    Ok(window
        .iter()
        .position(|&b| b == b'\n')
        .map_or(from, |i| from + i as u64 + 1))
}

/// Reads one planned stretch, never past its planned length; a file deleted since reads as empty.
pub fn read_segment(segment: &Segment) -> io::Result<Vec<u8>> {
    let mut file = match File::open(&segment.path) {
        Ok(file) => file,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    file.seek(SeekFrom::Start(segment.start))?;
    let mut bytes = Vec::new();
    file.take(segment.len).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Every planned stretch in order, as one block of text.
pub fn read_plan(plan: &RecentPlan) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    for segment in &plan.segments {
        bytes.extend(read_segment(segment)?);
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests;
