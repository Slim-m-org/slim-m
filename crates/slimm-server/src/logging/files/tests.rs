// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

/// A scratch directory removed when the test ends, pass or fail.
pub(in crate::logging) struct ScratchDir(pub PathBuf);

impl ScratchDir {
    pub(in crate::logging) fn new(name: &str) -> Self {
        Self(std::env::temp_dir().join(format!("slimm-{name}-{}", uuid::Uuid::now_v7())))
    }
}

impl Drop for ScratchDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn at(day: &str) -> Timestamp {
    format!("{day}T12:00:00Z").parse().unwrap()
}

fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().into_string().unwrap())
        .collect();
    names.sort();
    names
}

fn total_bytes(dir: &Path) -> u64 {
    list(dir).unwrap().iter().map(|f| f.bytes).sum()
}

fn limits(keep_days: u32, max_total_bytes: u64, max_file_bytes: u64) -> FileLimits {
    FileLimits {
        keep_days,
        max_total_bytes,
        max_file_bytes,
    }
}

#[test]
fn a_full_file_rolls_to_the_next_index_and_the_total_stays_bounded() {
    let dir = ScratchDir::new("log-roll");
    let mut files = RollingFiles::open(&dir.0, limits(14, 400, 100)).unwrap();
    let line = format!("{}\n", "x".repeat(49)).into_bytes();
    for _ in 0..40 {
        files.append(&line, at("2026-11-19")).unwrap();
        files.flush().unwrap();
        assert!(total_bytes(&dir.0) <= 400, "{}", total_bytes(&dir.0));
    }
    let names = names(&dir.0);
    assert_eq!(names.len(), 4, "{names:?}");
    assert_eq!(names.last().unwrap(), "slimm-server.2026-11-19.019.log");
}

#[test]
fn a_new_day_starts_a_new_file_and_old_days_are_deleted() {
    let dir = ScratchDir::new("log-days");
    let mut files = RollingFiles::open(&dir.0, limits(3, 1 << 20, 1 << 16)).unwrap();
    for day in [
        "2026-11-10",
        "2026-11-15",
        "2026-11-17",
        "2026-11-18",
        "2026-11-19",
    ] {
        files.append(b"line\n", at(day)).unwrap();
    }
    files.flush().unwrap();
    assert_eq!(
        names(&dir.0),
        [
            "slimm-server.2026-11-17.000.log",
            "slimm-server.2026-11-18.000.log",
            "slimm-server.2026-11-19.000.log",
        ]
    );
}

#[test]
fn a_restart_appends_to_todays_file_and_keeps_what_was_there() {
    let dir = ScratchDir::new("log-restart");
    let limits = limits(14, 1 << 20, 1 << 16);
    let mut first = RollingFiles::open(&dir.0, limits).unwrap();
    first
        .append(b"before the restart\n", at("2026-11-19"))
        .unwrap();
    first.flush().unwrap();
    drop(first);
    let mut second = RollingFiles::open(&dir.0, limits).unwrap();
    second
        .append(b"after the restart\n", at("2026-11-19"))
        .unwrap();
    second.flush().unwrap();
    assert_eq!(names(&dir.0), ["slimm-server.2026-11-19.000.log"]);
    let recent = recent(&dir.0, 1 << 20).unwrap();
    assert_eq!(recent.text, "before the restart\nafter the restart\n");
    assert!(!recent.truncated);
}

#[test]
fn recent_keeps_the_newest_whole_lines_across_files() {
    let dir = ScratchDir::new("log-recent");
    let mut files = RollingFiles::open(&dir.0, limits(14, 1 << 20, 12)).unwrap();
    for line in ["one 1\n", "two 22\n", "three 3\n", "four 44\n"] {
        files.append(line.as_bytes(), at("2026-11-19")).unwrap();
    }
    files.flush().unwrap();
    let everything = recent(&dir.0, 1 << 20).unwrap();
    assert_eq!(everything.text, "one 1\ntwo 22\nthree 3\nfour 44\n");
    let tail = recent(&dir.0, 12).unwrap();
    assert_eq!(tail.text, "four 44\n");
    assert!(tail.truncated);
}

#[test]
fn files_that_are_not_logs_are_left_alone() {
    let dir = ScratchDir::new("log-foreign");
    fs::create_dir_all(&dir.0).unwrap();
    fs::write(dir.0.join("notes.txt"), b"keep me").unwrap();
    let mut files = RollingFiles::open(&dir.0, limits(1, 10, 5)).unwrap();
    for _ in 0..5 {
        files.append(b"0123456789\n", at("2026-11-19")).unwrap();
    }
    assert!(dir.0.join("notes.txt").exists());
}

#[test]
fn a_missing_directory_downloads_as_empty() {
    let dir = ScratchDir::new("log-missing");
    assert_eq!(recent(&dir.0, 100).unwrap(), RecentLogs::default());
}
