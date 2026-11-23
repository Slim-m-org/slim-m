// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A run whose fuel slice ends while its indirect-call target is still being translated.

use std::time::{Duration, Instant};

use wasmi::{CompilationMode, Config, Engine, Linker, Module, Store};

use super::sliced::{FuelBudget, call_sliced};
use super::tests_fixtures::{GENEROUS, sha256_hex, wat};
use super::{ModuleHost, RunError};

const SWEEP: std::ops::Range<u32> = 60_000..400_000;

/// A callee big enough that translating it costs a large part of a fuel slice.
fn indirect_call_after_loop(iterations: u32) -> Vec<u8> {
    let callee_body = "(drop (i64.const 1)) ".repeat(6000) + "(i64.const 0)";
    wat(&format!(
        r#"(module
            (memory (export "memory") 1)
            (type $t (func (result i64)))
            (table 1 funcref)
            (elem (i32.const 0) $callee)
            (func $callee (type $t) {callee_body})
            (func (export "alloc") (param i32) (result i32) (i32.const 0))
            (func (export "run") (param i32 i32) (result i64) (local $i i32)
                (local.set $i (i32.const {iterations}))
                (loop $l
                  (local.set $i (i32.sub (local.get $i) (i32.const 1)))
                  (br_if $l (local.get $i)))
                (call_indirect (type $t) (i32.const 0))))"#
    ))
}

async fn run_through_the_host(iterations: u32) -> Result<Vec<u8>, RunError> {
    let wasm = indirect_call_after_loop(iterations);
    let sha256 = sha256_hex(&wasm);
    ModuleHost::run(wasm, sha256, GENEROUS, b"hi".to_vec()).await
}

fn run_on_a_lazy_engine(iterations: u32) -> Result<i64, RunError> {
    let mut config = Config::default();
    config.consume_fuel(true);
    config.compilation_mode(CompilationMode::Lazy);
    let engine = Engine::new(&config);
    let module = Module::new(&engine, indirect_call_after_loop(iterations)).expect("valid wasm");
    let mut store = Store::new(&engine, ());
    let instance = Linker::new(&engine)
        .instantiate_and_start(&mut store, &module)
        .expect("instantiates");
    let run = instance
        .get_typed_func::<(i32, i32), i64>(&store, "run")
        .expect("run export");
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut budget = FuelBudget::new(50_000_000);
    call_sliced(&mut store, &run, (0, 0), (&mut budget, deadline))
}

/// wasmi 0.51.5 panicked resuming here; 2.0.2 fails the call with a fuel error instead, so the engine stays eager.
#[tokio::test]
async fn a_run_resumed_after_a_fuel_slice_reaches_its_indirect_call() {
    for iterations in SWEEP.step_by(10_000) {
        let out = run_through_the_host(iterations).await;
        assert!(out.is_ok(), "{iterations} iterations: {out:?}");
    }
}

/// Run by hand after a wasmi upgrade: when it passes, lazy translation is safe and `compiled.rs` can drop `Eager`.
#[test]
#[ignore = "wasmi 2.0.2 fails a lazily translated call whose slice ends mid-translation"]
fn a_lazy_engine_survives_a_slice_ending_mid_translation() {
    for iterations in SWEEP.step_by(10_000) {
        let out = run_on_a_lazy_engine(iterations);
        assert!(out.is_ok(), "{iterations} iterations: {out:?}");
    }
}
