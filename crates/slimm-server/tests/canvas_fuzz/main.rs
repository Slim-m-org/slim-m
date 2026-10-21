// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Randomized property test for the server's canvas op model.
//!
//! Seeded sequences of place, move, resize, edit, erase, reorder, clear,
//! scoped clear, restore, lock, unlock and retried ops, from two to four
//! writers, run against a real store next to a reference model. Between steps
//! it checks that the table matches the model, that reference clients folding
//! the ops feed (cold-joined mid-run, or replayed from 0 with assorted page
//! sizes) land on the live table, that the viewport read matches a brute-force
//! filter, that the log is dense and its timestamps unique, and that the
//! compaction sweep never deletes an op that still undoes something.
//!
//! A violation is shrunk to a short step list and printed with its seed. Env:
//! `CANVAS_FUZZ_SEEDS` (default 32), `CANVAS_FUZZ_STEPS` (default 200),
//! `CANVAS_FUZZ_BASE` (first seed, default 1), `CANVAS_FUZZ_STATS` (print what
//! each seed range exercised) and `CANVAS_FUZZ_SKIP`, a comma list of
//! generator families to switch off so a run can dig past a known finding:
//! `dup_ids`, `cap_lower`, `degenerate`, `subnormal`, `sweep`, `retry`, `lock`,
//! `image`, `mods`, `restart` and `bulk`.
//!
//! Besides the sharded randomized runs, `repros` holds one small test per
//! finding, `racing` the cross-channel and concurrent-writer cases, `events`
//! the live frames against the feed, and `http_garbage` hostile bodies.

mod checks;
mod compare;
mod events;
#[path = "../canvas_ops/fixtures.rs"]
/// The canvas_ops binary's helpers, reused whole; this binary needs only some.
#[allow(dead_code)]
mod fixtures;
mod http_garbage;
mod oracle;
mod racing;
mod replay;
mod repros;
mod script;
mod shrink;
#[path = "../support/mod.rs"]
mod support;
mod world;

use std::collections::BTreeMap;

use script::{Cfg, Skip, Step, generate};
use world::Violation;

fn env_u64(name: &str, default: u64) -> u64 {
    std::env::var(name)
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

struct Finding {
    seed: u64,
    violation: Violation,
    minimal: Vec<Step>,
    hits: u32,
}

fn render(findings: &BTreeMap<String, Finding>) -> String {
    let mut out = String::new();
    for (sig, f) in findings {
        out += &format!(
            "\n=== {sig} (seen in {} seeds; first seed {}, step {})\n{}\n",
            f.hits, f.seed, f.violation.step, f.violation.detail
        );
        out += &format!("minimal sequence ({} steps):\n", f.minimal.len());
        for s in &f.minimal {
            out += &format!("  #{} w{} {:?}\n", s.label, s.writer, s.act);
        }
    }
    out
}

async fn shard(index: u64, of: u64) {
    let seeds = env_u64("CANVAS_FUZZ_SEEDS", 32);
    let steps = env_u64("CANVAS_FUZZ_STEPS", 200) as usize;
    let base = env_u64("CANVAS_FUZZ_BASE", 1);
    let skip = Skip::parse(&std::env::var("CANVAS_FUZZ_SKIP").unwrap_or_default());
    let mut found: BTreeMap<String, Finding> = BTreeMap::new();
    let mut soft: BTreeMap<String, (u64, Violation, u32)> = BTreeMap::new();
    let mut stats: BTreeMap<String, u64> = BTreeMap::new();
    for seed in (base..base + seeds).filter(|s| s % of == index) {
        let cfg = Cfg::for_seed(seed, steps, &skip);
        let script = generate(seed, &cfg);
        let report = world::run(&script, &cfg, seed).await;
        for (k, n) in report.stats {
            *stats.entry(k).or_default() += n;
        }
        for s in report.soft {
            soft.entry(s.sig.clone())
                .and_modify(|e| e.2 += 1)
                .or_insert((seed, s, 1));
        }
        let Some(violation) = report.fatal else {
            continue;
        };
        if let Some(known) = found.get_mut(&violation.sig) {
            known.hits += 1;
            continue;
        }
        let minimal = shrink::shrink(script, &cfg, seed, &violation.sig, violation.step, 400).await;
        found.insert(
            violation.sig.clone(),
            Finding {
                seed,
                violation,
                minimal,
                hits: 1,
            },
        );
    }
    let mut report = render(&found);
    for (sig, (seed, s, hits)) in &soft {
        report += &format!(
            "\n--- soft {sig} (seed {seed}, {hits} hits): {}\n",
            s.detail
        );
    }
    if std::env::var("CANVAS_FUZZ_STATS").is_ok() {
        report += &format!("\ncoverage: {stats:?}\n");
    }
    eprintln!("{report}");
    assert!(found.is_empty(), "canvas fuzz violations:{report}");
}

macro_rules! shards {
    ($($name:ident => $n:expr),* $(,)?) => {
        $(#[tokio::test]
        async fn $name() {
            shard($n, 8).await;
        })*
    };
}

shards!(shard_0 => 0, shard_1 => 1, shard_2 => 2, shard_3 => 3, shard_4 => 4, shard_5 => 5, shard_6 => 6, shard_7 => 7);
