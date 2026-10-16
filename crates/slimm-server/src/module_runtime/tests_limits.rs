// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The store limiter's table/memory/instance bounds, the response cap, the
//! wall-clock stop and trap wording, each proven against real wasm. The
//! resource assertions measure the process rather than only the error: a
//! refusal that arrives after the allocation has already happened is a bug.

use std::time::Duration;

use super::{ModuleHost, RunError, RunLimits};

const LIMITS: RunLimits = RunLimits {
    memory_bytes: 4 * 1024 * 1024,
    fuel: 50_000_000,
    wall: Duration::from_millis(500),
};

fn module(body: &str) -> Vec<u8> {
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (func (export "alloc") (param i32) (result i32) (i32.const 0))
            {body})"#
    );
    wat::parse_str(text).expect("fixture WAT must parse")
}

fn run_export(body: &str) -> String {
    format!(r#"(func (export "run") (param i32 i32) (result i64) {body})"#)
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    crate::media::to_hex(&Sha256::digest(bytes))
}

async fn run(wasm: Vec<u8>, limits: RunLimits) -> Result<Vec<u8>, RunError> {
    let sha = sha256_hex(&wasm);
    ModuleHost::run(wasm, sha, limits, b"hi".to_vec()).await
}

fn proc_status_kib(key: &str) -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let line = status.lines().find(|l| l.starts_with(key)).unwrap();
    line.split_whitespace().nth(1).unwrap().parse().unwrap()
}

fn cpu_seconds() -> f64 {
    let stat = std::fs::read_to_string("/proc/self/stat").unwrap();
    let after_comm = stat.rsplit_once(')').unwrap().1;
    let fields: Vec<&str> = after_comm.split_whitespace().collect();
    let ticks: u64 = fields[11].parse::<u64>().unwrap() + fields[12].parse::<u64>().unwrap();
    ticks as f64 / 100.0
}

#[tokio::test]
async fn a_huge_declared_table_is_refused_before_it_is_allocated() {
    let wasm = module(&format!(
        "(table 400000000 funcref) {}",
        run_export("(i64.const 0)")
    ));
    // Resets the kernel's peak-RSS watermark so VmHWM covers only this run.
    std::fs::write("/proc/self/clear_refs", "5").unwrap();
    let before = proc_status_kib("VmHWM:");

    let err = run(wasm, LIMITS).await.expect_err("table must be refused");

    let grew_mib = (proc_status_kib("VmHWM:") - before.min(proc_status_kib("VmHWM:"))) / 1024;
    assert!(
        matches!(&err, RunError::Instantiate(m) if m.contains("table")),
        "{err}"
    );
    assert!(grew_mib < 64, "peak RSS grew {grew_mib} MiB");
}

#[tokio::test]
async fn a_second_table_or_memory_is_refused() {
    let tables = module(&format!(
        "(table 1 funcref) (table 1 funcref) {}",
        run_export("(i64.const 0)")
    ));
    let err = run(tables, LIMITS).await.expect_err("two tables refused");
    assert!(matches!(err, RunError::Instantiate(_)), "{err}");

    let memories = module(&format!("(memory 1) {}", run_export("(i64.const 0)")));
    let err = run(memories, LIMITS)
        .await
        .expect_err("two memories refused");
    assert!(matches!(err, RunError::Instantiate(_)), "{err}");
}

#[tokio::test]
async fn a_modest_table_still_runs() {
    let wasm = module(&format!(
        "(table 1000 funcref) {}",
        run_export("(i64.const 0)")
    ));
    assert!(run(wasm, LIMITS).await.is_ok());
}

#[tokio::test]
async fn a_response_over_the_cap_is_refused_not_copied() {
    // 2 MiB response out of a 3 MiB memory: inside the memory, over the cap.
    let wasm = wat::parse_str(
        r#"(module
            (memory (export "memory") 48)
            (func (export "alloc") (param i32) (result i32) (i32.const 0))
            (func (export "run") (param i32 i32) (result i64) (i64.const 0x200000)))"#,
    )
    .unwrap();
    let err = run(wasm, LIMITS).await.expect_err("oversized response");
    assert!(
        matches!(&err, RunError::ResourceLimited(m) if m.contains("response")),
        "{err}"
    );
}

#[tokio::test]
async fn a_timed_out_module_stops_burning_cpu() {
    let wasm = module(&run_export("(loop $l (br $l)) (i64.const 0)"));
    let limits = RunLimits {
        fuel: 2_000_000_000,
        wall: Duration::from_millis(100),
        ..LIMITS
    };

    let err = run(wasm, limits).await.expect_err("must time out");
    assert!(matches!(err, RunError::Timeout), "{err}");

    tokio::time::sleep(Duration::from_millis(300)).await;
    let start = cpu_seconds();
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let burned = cpu_seconds() - start;
    assert!(
        burned < 0.3,
        "wasm kept burning {burned}s of CPU after the timeout"
    );
}

#[tokio::test]
async fn a_trap_reads_as_a_sentence_not_an_enum_name() {
    let wasm = module(&run_export("(unreachable)"));
    let err = run(wasm, LIMITS).await.expect_err("must trap");
    let text = err.to_string();
    assert!(text.contains("unreachable"), "{text}");
    assert!(!text.contains("UnreachableCodeReached"), "{text}");

    let wasm = module(&run_export("(i64.load (i32.const 70000))"));
    let text = run(wasm, LIMITS).await.expect_err("must trap").to_string();
    assert!(text.contains("outside its memory"), "{text}");
    assert!(!text.contains("MemoryOutOfBounds"), "{text}");
}

fn counting_loop(iterations: u32) -> Vec<u8> {
    module(&format!(
        r#"(func (export "run") (param i32 i32) (result i64) (local $i i32)
            (local.set $i (i32.const {iterations}))
            (loop $l
              (local.set $i (i32.sub (local.get $i) (i32.const 1)))
              (br_if $l (local.get $i)))
            (i64.const 0))"#
    ))
}

#[tokio::test]
async fn a_module_can_spend_its_declared_fuel_across_alloc_and_run() {
    let limits = RunLimits {
        fuel: 1_150_000,
        ..LIMITS
    };
    let out = run(counting_loop(100_000), limits).await;
    assert!(
        out.is_ok(),
        "fuel handed out but never burned was lost: {out:?}"
    );
}

#[tokio::test]
async fn a_module_still_runs_out_of_a_budget_it_overspends() {
    let limits = RunLimits {
        fuel: 200_000,
        ..LIMITS
    };
    let err = run(counting_loop(100_000), limits)
        .await
        .expect_err("over budget");
    assert!(matches!(err, RunError::ResourceLimited(_)), "{err}");
}

struct SlowCountingPoster {
    calls: std::sync::atomic::AtomicU32,
    delay: Duration,
}

impl super::MessagePoster for SlowCountingPoster {
    fn post(&self, _channel: Option<&str>, _content: &str) -> Result<String, super::PostRefused> {
        self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        std::thread::sleep(self.delay);
        Ok("posted".to_owned())
    }
}

#[tokio::test]
async fn a_host_call_after_the_deadline_is_refused() {
    let request = r#"{"capability":"message.post","content":"hi"}"#;
    let wasm = wat::parse_str(format!(
        r#"(module
            (import "slim" "host_call" (func $host_call (param i32 i32) (result i64)))
            (memory (export "memory") 1)
            (global $bump (mut i32) (i32.const 8192))
            (data (i32.const 1024) "{}")
            (func (export "alloc") (param $len i32) (result i32)
                (local $ptr i32)
                (local.set $ptr (global.get $bump))
                (global.set $bump (i32.add (global.get $bump) (local.get $len)))
                (local.get $ptr))
            (func (export "run") (param i32 i32) (result i64)
                (drop (call $host_call (i32.const 1024) (i32.const {len})))
                (call $host_call (i32.const 1024) (i32.const {len}))))"#,
        request.replace('"', "\\\""),
        len = request.len()
    ))
    .unwrap();
    let poster = std::sync::Arc::new(SlowCountingPoster {
        calls: Default::default(),
        delay: Duration::from_millis(150),
    });
    let surface = super::CapabilitySurface::enabled(
        vec!["message.post".to_owned()],
        "deadline-module",
        std::sync::Arc::new(super::InMemoryKv::default()),
    )
    .with_poster(poster.clone());
    let limits = RunLimits {
        wall: Duration::from_millis(50),
        ..LIMITS
    };

    let sha = sha256_hex(&wasm);
    let err = ModuleHost::run_with_capabilities(wasm, sha, limits, b"hi".to_vec(), surface)
        .await
        .expect_err("the wall clock passes during the first post");
    assert!(matches!(err, RunError::Timeout), "{err}");
    tokio::time::sleep(Duration::from_millis(400)).await;

    assert_eq!(
        poster.calls.load(std::sync::atomic::Ordering::SeqCst),
        1,
        "the second post ran after the deadline"
    );
}
