// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use std::fs::{self, OpenOptions};
use std::io::Write;

use jiff::Timestamp;

use super::*;
use crate::logging::files::tests::ScratchDir;
use crate::logging::{FileLimits, RollingFiles};

fn today() -> Date {
    "2026-11-19".parse().unwrap()
}

fn noon() -> Timestamp {
    "2026-11-19T12:00:00Z".parse().unwrap()
}

fn text(dir: &Path, max_bytes: u64) -> (String, bool) {
    let plan = plan_recent(dir, max_bytes, today()).unwrap();
    let bytes = read_plan(&plan).unwrap();
    (String::from_utf8(bytes).unwrap(), plan.truncated)
}

fn written(dir: &Path, max_file_bytes: u64, lines: &[&str]) {
    let limits = FileLimits {
        keep_days: 14,
        max_total_bytes: 1 << 20,
        max_file_bytes,
    };
    let mut files = RollingFiles::open(dir, limits).unwrap();
    for line in lines {
        files.append(line.as_bytes(), noon()).unwrap();
    }
    files.flush().unwrap();
}

#[test]
fn the_newest_whole_lines_are_kept_across_files() {
    let dir = ScratchDir::new("log-recent");
    written(
        &dir.0,
        12,
        &["one 1\n", "two 22\n", "three 3\n", "four 44\n"],
    );
    assert_eq!(
        text(&dir.0, 1 << 20),
        ("one 1\ntwo 22\nthree 3\nfour 44\n".to_owned(), false)
    );
    assert_eq!(text(&dir.0, 12), ("four 44\n".to_owned(), true));
}

#[test]
fn a_file_that_grows_after_planning_is_read_only_as_far_as_planned() {
    let dir = ScratchDir::new("log-growing");
    written(&dir.0, 1 << 16, &["planned\n"]);
    let plan = plan_recent(&dir.0, 64, today()).unwrap();
    let path = &plan.segments[0].path;
    let mut grows = OpenOptions::new().append(true).open(path).unwrap();
    grows.write_all("x".repeat(4096).as_bytes()).unwrap();
    assert_eq!(read_plan(&plan).unwrap(), b"planned\n");
}

#[test]
fn a_file_deleted_after_planning_reads_as_empty() {
    let dir = ScratchDir::new("log-vanished");
    written(&dir.0, 1 << 16, &["gone soon\n"]);
    let plan = plan_recent(&dir.0, 64, today()).unwrap();
    fs::remove_file(&plan.segments[0].path).unwrap();
    assert_eq!(read_plan(&plan).unwrap(), b"");
}

#[test]
fn a_file_dated_after_today_is_not_the_newest() {
    let dir = ScratchDir::new("log-ahead");
    written(&dir.0, 1 << 16, &["today\n"]);
    fs::write(
        dir.0.join("slimm-server.2031-01-01.000.log"),
        b"from the future\n",
    )
    .unwrap();
    assert_eq!(text(&dir.0, 1 << 20), ("today\n".to_owned(), false));
}

#[test]
fn a_missing_directory_plans_nothing() {
    let dir = ScratchDir::new("log-missing");
    assert_eq!(
        plan_recent(&dir.0, 100, today()).unwrap(),
        RecentPlan::default()
    );
}
