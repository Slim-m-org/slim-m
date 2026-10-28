// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What this machine has: cores, memory, and free disk on the data volume.

use std::path::Path;

/// Cores this process may use. Rust's own count already honours a cgroup CPU quota.
pub fn cores() -> f64 {
    std::thread::available_parallelism().map_or(1.0, |n| n.get() as f64)
}

/// Total RAM of the host in bytes, from the first `MemTotal` line.
pub fn total_memory_bytes() -> Option<u64> {
    let meminfo = std::fs::read_to_string("/proc/meminfo").ok()?;
    parse_mem_total(&meminfo)
}

fn parse_mem_total(meminfo: &str) -> Option<u64> {
    let line = meminfo.lines().find_map(|l| l.strip_prefix("MemTotal:"))?;
    let kb: u64 = line.split_whitespace().next()?.parse().ok()?;
    kb.checked_mul(1024)
}

/// Free and total bytes of the volume holding `path`; free is what an
/// unprivileged process may use, not what the filesystem reports unreserved.
/// The widening casts are needed where `statvfs` fields are narrower than glibc's.
#[cfg(unix)]
pub fn disk_bytes(path: &Path) -> Option<(u64, u64)> {
    use std::os::unix::ffi::OsStrExt;
    let c_path = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
    let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
    // SAFETY: c_path is NUL-terminated and stat is a valid out pointer; the value is read only on success.
    let status = unsafe { libc::statvfs(c_path.as_ptr(), stat.as_mut_ptr()) };
    if status != 0 {
        return None;
    }
    // SAFETY: statvfs returned 0, so it initialised the struct.
    let stat = unsafe { stat.assume_init() };
    #[allow(clippy::useless_conversion)]
    let (block, available, blocks) = (
        u64::from(stat.f_frsize),
        u64::from(stat.f_bavail),
        u64::from(stat.f_blocks),
    );
    Some((
        available.saturating_mul(block),
        blocks.saturating_mul(block),
    ))
}

#[cfg(not(unix))]
pub fn disk_bytes(_path: &Path) -> Option<(u64, u64)> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_mem_total_in_bytes() {
        let sample = "MemTotal:       16384000 kB\nMemFree:  100 kB\n";
        assert_eq!(parse_mem_total(sample), Some(16_384_000 * 1024));
    }

    #[test]
    fn a_missing_mem_total_is_none() {
        assert_eq!(parse_mem_total("MemFree: 5 kB\n"), None);
    }
}

#[cfg(all(test, unix))]
mod unix_tests {
    use super::disk_bytes;

    #[test]
    fn the_temp_volume_reports_space() {
        let (free, total) = disk_bytes(&std::env::temp_dir()).expect("statvfs");
        assert!(total > 0 && free <= total);
    }
}
