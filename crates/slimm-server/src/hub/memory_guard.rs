// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Refuses a new WebSocket connection when the process is near its cgroup
//! memory ceiling, after a capacity study found the kernel OOM-killing the
//! server mid-ramp. It never touches an open connection, and admits always
//! when no limit is discoverable. How the limit, usage signal and reserve
//! were chosen is in docs/internals.md.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// See "Choosing the reserve" above.
const RESERVE_BYTES: u64 = 64 * 1024 * 1024;

/// See "Caching" above.
const CACHE_TTL: Duration = Duration::from_millis(250);

const CGROUP_V2_ROOT: &str = "/sys/fs/cgroup";
const CGROUP_V1_MEMORY_ROOT: &str = "/sys/fs/cgroup/memory";

/// Cgroup v1's sentinel for "no limit configured": `LONG_MAX` rounded down
/// to a page boundary on a 64-bit kernel. No real deployment configures a
/// limit anywhere close to this, so treating anything at or above it as
/// unlimited is safe.
const V1_UNLIMITED_THRESHOLD: u64 = 1 << 62;

/// A memory reading: how much this process may use, and how much of that
/// this guard counts as truly in use. Either half is `None` when it could
/// not be determined; see [`decide`] for what that means for admission.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MemoryReading {
    pub limit_bytes: Option<u64>,
    pub usage_bytes: Option<u64>,
}

/// A snapshot of the guard's own view, for `/metrics`.
pub struct MemoryAdmissionSnapshot {
    pub limit_bytes: Option<u64>,
    pub usage_bytes: Option<u64>,
    pub refused_total: u64,
}

/// Where a [`MemoryReading`] comes from - the seam the admission decision is
/// tested through instead of a path read buried inside it. Production reads
/// the real cgroup files; tests supply a fixed or shared reading.
trait MemorySource: Send + Sync {
    fn read(&self) -> MemoryReading;
}

struct CgroupSource;

impl MemorySource for CgroupSource {
    fn read(&self) -> MemoryReading {
        MemoryReading {
            limit_bytes: discover_limit(),
            usage_bytes: discover_usage(),
        }
    }
}

fn discover_limit() -> Option<u64> {
    if let Ok(raw) = std::env::var("SLIMM_MEMORY_LIMIT_BYTES")
        && let Ok(bytes) = raw.trim().parse::<u64>()
    {
        return Some(bytes);
    }
    v2_limited_dir()
        .map(|(_, limit)| limit)
        .or_else(read_v1_limit)
}

fn discover_usage() -> Option<u64> {
    let dir = v2_limited_dir().map_or_else(|| PathBuf::from(CGROUP_V2_ROOT), |(dir, _)| dir);
    read_v2_usage(&dir).or_else(read_v1_usage)
}

/// The cgroup v2 directory that bounds this process, and its limit.
fn v2_limited_dir() -> Option<(PathBuf, u64)> {
    let self_cgroup = std::fs::read_to_string("/proc/self/cgroup").unwrap_or_default();
    nearest_v2_limit(Path::new(CGROUP_V2_ROOT), &self_cgroup)
}

/// Walks from the process's own cgroup (the `0::<path>` line of
/// `/proc/self/cgroup`) up to `root`, returning the first directory with a
/// numeric `memory.max`. Inside a container with its own cgroup namespace the
/// path is `/` and this reads the root, as before; on a host or under a
/// systemd slice the limit lives further down, where reading only the root
/// found nothing.
fn nearest_v2_limit(root: &Path, self_cgroup: &str) -> Option<(PathBuf, u64)> {
    let relative = self_cgroup
        .lines()
        .find_map(|line| line.strip_prefix("0::"))
        .map_or("", |path| path.trim().trim_start_matches('/'));
    let mut dir = root.join(relative);
    loop {
        if let Some(limit) = read_v2_limit(&dir) {
            return Some((dir, limit));
        }
        if dir == root || !dir.pop() || !dir.starts_with(root) {
            return None;
        }
    }
}

fn read_v2_limit(dir: &Path) -> Option<u64> {
    let raw = std::fs::read_to_string(dir.join("memory.max")).ok()?;
    let raw = raw.trim();
    if raw == "max" {
        return None;
    }
    raw.parse().ok()
}

fn read_v2_usage(dir: &Path) -> Option<u64> {
    let current = read_u64_file(&dir.join("memory.current"))?;
    let stat = std::fs::read_to_string(dir.join("memory.stat")).ok()?;
    let inactive_file = parse_stat_field(&stat, "inactive_file").unwrap_or(0);
    Some(current.saturating_sub(inactive_file))
}

fn read_v1_limit() -> Option<u64> {
    let raw = read_u64_file(&Path::new(CGROUP_V1_MEMORY_ROOT).join("memory.limit_in_bytes"))?;
    if raw >= V1_UNLIMITED_THRESHOLD {
        return None;
    }
    Some(raw)
}

fn read_v1_usage() -> Option<u64> {
    let current = read_u64_file(&Path::new(CGROUP_V1_MEMORY_ROOT).join("memory.usage_in_bytes"))?;
    let stat =
        std::fs::read_to_string(Path::new(CGROUP_V1_MEMORY_ROOT).join("memory.stat")).ok()?;
    let inactive_file = parse_stat_field(&stat, "total_inactive_file")
        .or_else(|| parse_stat_field(&stat, "inactive_file"))
        .unwrap_or(0);
    Some(current.saturating_sub(inactive_file))
}

fn read_u64_file(path: &Path) -> Option<u64> {
    std::fs::read_to_string(path).ok()?.trim().parse().ok()
}

/// Finds `field`'s value in a `memory.stat`-shaped `"<key> <value>"` per
/// line file. `None` if the field is absent, rather than defaulting - the
/// caller decides what a missing field means for its own computation.
fn parse_stat_field(stat: &str, field: &str) -> Option<u64> {
    stat.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        if parts.next()? != field {
            return None;
        }
        parts.next()?.parse().ok()
    })
}

/// The pure admission decision: admit unless both halves of `reading` are
/// known and the headroom between them is under `reserve_bytes`. Either
/// half missing means "cannot tell", and a guard that misfires on
/// incomplete data is worse than one that stays out of the way, so
/// incomplete data admits.
fn decide(reading: MemoryReading, reserve_bytes: u64) -> bool {
    match (reading.limit_bytes, reading.usage_bytes) {
        (Some(limit), Some(usage)) => limit.saturating_sub(usage) >= reserve_bytes,
        _ => true,
    }
}

struct Cache {
    reading: MemoryReading,
    read_at: Instant,
}

/// The stateful guard: caches readings from a [`MemorySource`] and counts
/// refusals. Cheap to clone-share via `Arc`, the way [`super::Hub`] holds
/// one.
pub struct MemoryGuard {
    source: Box<dyn MemorySource>,
    cache: Mutex<Cache>,
    refused_total: AtomicU64,
}

struct SharedReading(Arc<Mutex<MemoryReading>>);

impl MemorySource for SharedReading {
    fn read(&self) -> MemoryReading {
        *self
            .0
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }
}

impl MemoryGuard {
    pub(super) fn new() -> Self {
        Self::with_source(Box::new(CgroupSource))
    }

    /// Builds a guard backed by a caller-controlled reading instead of the
    /// real cgroup files, so a test can flip the answer after connections
    /// already exist. See `tests/memory_admission.rs`.
    pub(super) fn with_shared_reading(shared: Arc<Mutex<MemoryReading>>) -> Self {
        Self::with_source(Box::new(SharedReading(shared)))
    }

    fn with_source(source: Box<dyn MemorySource>) -> Self {
        Self {
            source,
            cache: Mutex::new(Cache {
                reading: MemoryReading::default(),
                read_at: Instant::now() - CACHE_TTL - Duration::from_millis(1),
            }),
            refused_total: AtomicU64::new(0),
        }
    }

    fn reading(&self) -> MemoryReading {
        let mut cache = self
            .cache
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if cache.read_at.elapsed() >= CACHE_TTL {
            cache.reading = self.source.read();
            cache.read_at = Instant::now();
        }
        cache.reading
    }

    /// Whether a new connection should be admitted right now. Never called
    /// for a connection already open.
    pub(super) fn admit(&self) -> bool {
        let admitted = decide(self.reading(), RESERVE_BYTES);
        if !admitted {
            self.refused_total.fetch_add(1, Ordering::Relaxed);
        }
        admitted
    }

    pub(super) fn snapshot(&self) -> MemoryAdmissionSnapshot {
        let reading = self.reading();
        MemoryAdmissionSnapshot {
            limit_bytes: reading.limit_bytes,
            usage_bytes: reading.usage_bytes,
            refused_total: self.refused_total.load(Ordering::Relaxed),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FixedReading(MemoryReading);

    impl MemorySource for FixedReading {
        fn read(&self) -> MemoryReading {
            self.0
        }
    }

    #[test]
    fn inert_with_no_discoverable_limit() {
        let guard = MemoryGuard::with_source(Box::new(FixedReading(MemoryReading {
            limit_bytes: None,
            usage_bytes: Some(999_999_999),
        })));
        assert!(
            guard.admit(),
            "no limit means the guard stays out of the way"
        );
        assert_eq!(guard.snapshot().refused_total, 0);
    }

    #[test]
    fn inert_when_usage_cannot_be_determined() {
        let guard = MemoryGuard::with_source(Box::new(FixedReading(MemoryReading {
            limit_bytes: Some(100),
            usage_bytes: None,
        })));
        assert!(guard.admit(), "a limit with no usage reading cannot decide");
    }

    #[test]
    fn refuses_below_the_reserve_and_admits_above_it() {
        assert!(!decide(
            MemoryReading {
                limit_bytes: Some(1_000),
                usage_bytes: Some(950),
            },
            100,
        ));
        assert!(decide(
            MemoryReading {
                limit_bytes: Some(1_000),
                usage_bytes: Some(800),
            },
            100,
        ));
        assert!(
            decide(
                MemoryReading {
                    limit_bytes: Some(1_000),
                    usage_bytes: Some(900),
                },
                100,
            ),
            "exactly the reserve's worth of headroom still admits"
        );
    }

    #[test]
    fn a_real_guard_refuses_and_counts_it() {
        let guard = MemoryGuard::with_source(Box::new(FixedReading(MemoryReading {
            limit_bytes: Some(100),
            usage_bytes: Some(90),
        })));
        assert!(!guard.admit());
        assert!(!guard.admit());
        assert_eq!(guard.snapshot().refused_total, 2);
    }

    #[test]
    fn parses_a_realistic_memory_stat_sample() {
        let stat = "anon 12345678\nfile 87654321\nkernel_stack 32768\n\
                     active_file 5000000\ninactive_file 2000000\nslab 1000000\n";
        assert_eq!(parse_stat_field(stat, "inactive_file"), Some(2_000_000));
        assert_eq!(parse_stat_field(stat, "anon"), Some(12_345_678));
    }

    #[test]
    fn a_missing_field_in_memory_stat_is_none_not_a_default() {
        let stat = "anon 12345678\nfile 87654321\n";
        assert_eq!(parse_stat_field(stat, "inactive_file"), None);
    }

    fn fake_tree(name: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("{name}-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(root.join("user.slice/app.scope")).unwrap();
        std::fs::write(root.join("memory.max"), "max\n").unwrap();
        std::fs::write(root.join("user.slice/memory.max"), "1073741824\n").unwrap();
        std::fs::write(root.join("user.slice/app.scope/memory.max"), "max\n").unwrap();
        root
    }

    #[test]
    fn the_limit_is_found_on_the_nearest_ancestor_of_the_process_cgroup() {
        let root = fake_tree("slimm-cgroup-nested");
        let found = nearest_v2_limit(&root, "0::/user.slice/app.scope\n");
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(found, Some((root.join("user.slice"), 1_073_741_824)));
    }

    #[test]
    fn a_namespaced_process_reads_the_root_and_unlimited_is_none() {
        let root = fake_tree("slimm-cgroup-root");
        let found = nearest_v2_limit(&root, "0::/\n");
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(found, None);
    }
}
