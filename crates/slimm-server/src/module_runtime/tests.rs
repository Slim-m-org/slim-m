// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! [`ModuleHost`] against hand-written WAT, compiled to wasm at test time so
//! each fixture's exact behavior - an infinite loop, a declared import, an
//! oversized memory - is readable right here rather than shipped as an
//! opaque checked-in binary.

use std::sync::Arc;
use std::time::Duration;

use super::tests_fixtures::*;
use super::{CapabilitySurface, InMemoryKv, ModuleHost, RunError, RunLimits};

/// The surface is off for a module with no approved capabilities, so one
/// importing `host_call` is refused exactly like any other import.
#[tokio::test]
async fn a_host_call_module_is_refused_when_the_surface_is_off() {
    let wasm = host_call_wasm(r#"{"capability":"kv.store"}"#);
    let sha256 = sha256_hex(&wasm);

    let err = ModuleHost::run(wasm, sha256, GENEROUS, b"hi".to_vec())
        .await
        .expect_err("host_call must be refused while the surface is off");

    assert!(matches!(err, RunError::ImportsNotAllowed));
}

/// With the surface on and a capability approved, the `host_call` import links
/// (the module instantiates and runs), and an approved capability the host does
/// not implement comes back a clean refusal rather than a trap.
#[tokio::test]
async fn an_enabled_host_call_instantiates_and_an_unimplemented_capability_is_refused() {
    let wasm = host_call_wasm(r#"{"capability":"message.post","text":"hi"}"#);
    let sha256 = sha256_hex(&wasm);
    let surface = CapabilitySurface::enabled(
        vec!["message.post".to_owned()],
        "test-module",
        Arc::new(InMemoryKv::default()),
    );

    let output = ModuleHost::run_with_capabilities(wasm, sha256, GENEROUS, b"hi".to_vec(), surface)
        .await
        .expect("the module should instantiate and its host_call should answer");

    let text = String::from_utf8(output).expect("the response is UTF-8 JSON");
    assert!(text.contains(r#""ok":false"#), "{text}");
    assert!(text.contains("message.post needs a channel"), "{text}");
}

/// The `kv.store` capability, end to end through the real wasm `host_call`: a
/// `set` in one run is readable by a `get` in a later run sharing the same
/// backend - the whole path (import, memory read, gate, kv, alloc-and-write
/// back) works, and the capability persists across runs.
#[tokio::test]
async fn kv_store_round_trips_across_runs_through_host_call() {
    let kv = Arc::new(InMemoryKv::default());

    let set = host_call_wasm(r#"{"capability":"kv.store","op":"set","key":"score","value":"42"}"#);
    let out = ModuleHost::run_with_capabilities(
        set.clone(),
        sha256_hex(&set),
        GENEROUS,
        b"hi".to_vec(),
        CapabilitySurface::enabled(vec!["kv.store".to_owned()], "game", kv.clone()),
    )
    .await
    .expect("set should run");
    assert!(String::from_utf8(out).unwrap().contains(r#""ok":true"#));

    let get = host_call_wasm(r#"{"capability":"kv.store","op":"get","key":"score"}"#);
    let out = ModuleHost::run_with_capabilities(
        get.clone(),
        sha256_hex(&get),
        GENEROUS,
        b"hi".to_vec(),
        CapabilitySurface::enabled(vec!["kv.store".to_owned()], "game", kv.clone()),
    )
    .await
    .expect("get should run");
    assert!(String::from_utf8(out).unwrap().contains(r#""value":"42""#));
}

/// The surface being on is not enough: with no capability approved for the
/// module, even the `host_call` import is refused.
#[tokio::test]
async fn an_enabled_surface_with_no_approved_capability_refuses_the_import() {
    let wasm = host_call_wasm(r#"{"capability":"kv.store"}"#);
    let sha256 = sha256_hex(&wasm);
    let surface = CapabilitySurface::enabled(vec![], "m", Arc::new(InMemoryKv::default()));

    let err = ModuleHost::run_with_capabilities(wasm, sha256, GENEROUS, b"hi".to_vec(), surface)
        .await
        .expect_err("no approved capability means no host_call import");

    assert!(matches!(err, RunError::ImportsNotAllowed));
}

/// Only `slim.host_call` is ever allowed: any other import is refused even with
/// the surface on and a capability approved.
#[tokio::test]
async fn any_other_import_is_refused_even_with_the_surface_on() {
    let wasm = importing_wasm(); // imports env.log
    let sha256 = sha256_hex(&wasm);
    let surface = CapabilitySurface::enabled(
        vec!["kv.store".to_owned()],
        "m",
        Arc::new(InMemoryKv::default()),
    );

    let err = ModuleHost::run_with_capabilities(wasm, sha256, GENEROUS, b"hi".to_vec(), surface)
        .await
        .expect_err("only slim.host_call may be imported");

    assert!(matches!(err, RunError::ImportsNotAllowed));
}

#[tokio::test]
async fn run_returns_the_modules_own_output() {
    let wasm = echo_upper_wasm();
    let sha256 = sha256_hex(&wasm);

    let output = ModuleHost::run(wasm, sha256, GENEROUS, b"hello there".to_vec())
        .await
        .expect("a conforming module should run");

    assert_eq!(output, b"HELLO THERE");
}

/// The response region `run` hands back is the module's claim, not the host's
/// fact: one that does not fit inside the module's memory is refused as the
/// module's own bug, and never turned into a host-side allocation of that
/// claimed size.
#[tokio::test]
async fn a_response_region_outside_the_modules_memory_is_refused_not_allocated() {
    let wasm = oversized_output_wasm();
    let sha256 = sha256_hex(&wasm);

    let err = ModuleHost::run(wasm, sha256, GENEROUS, b"hi".to_vec())
        .await
        .expect_err("a 4 GiB response claim from a 64 KiB module must be refused");

    assert!(matches!(err, RunError::Trap(_)), "{err}");
}

/// The same rule for the request a module hands `host_call`: a length that
/// does not fit its memory yields the empty (`0`) response, not an allocation.
#[tokio::test]
async fn an_oversized_host_call_request_yields_the_empty_response() {
    let wasm = oversized_host_call_wasm();
    let sha256 = sha256_hex(&wasm);
    let surface = CapabilitySurface::enabled(
        vec!["kv.store".to_owned()],
        "m",
        Arc::new(InMemoryKv::default()),
    );

    let output = ModuleHost::run_with_capabilities(wasm, sha256, GENEROUS, b"hi".to_vec(), surface)
        .await
        .expect("the module itself runs to completion");

    assert!(output.is_empty());
}

/// Compilation is cached by the verified digest, so a second run of the same
/// artifact skips it; each run still gets its own instance, so the module's
/// bump allocator starts fresh and the output is identical.
#[tokio::test]
async fn a_repeated_run_reuses_the_compiled_module_with_a_fresh_instance() {
    let wasm = echo_upper_wasm();
    let sha256 = sha256_hex(&wasm);

    for _ in 0..2 {
        let output = ModuleHost::run(wasm.clone(), sha256.clone(), GENEROUS, b"again".to_vec())
            .await
            .expect("a conforming module should run");
        assert_eq!(output, b"AGAIN");
        assert!(super::compiled::is_cached(&sha256));
    }
}

/// The cache is bounded: past [`super::compiled::MAX_CACHED_MODULES`] distinct
/// artifacts it is dropped and refilled, so the first one compiled is gone
/// and the cache never holds more than the bound. Only eviction is asserted,
/// never that the latest survived: other tests in the same process share the
/// cache and may clear it too, which only makes eviction more certain.
#[tokio::test]
async fn the_compiled_module_cache_evicts_past_its_bound() {
    let first = distinct_wasm(1_000);
    let first_sha = sha256_hex(&first);
    ModuleHost::run(first.clone(), first_sha.clone(), GENEROUS, b"a".to_vec())
        .await
        .expect("a conforming module should run");
    assert!(super::compiled::is_cached(&first_sha));

    for n in 1_001..=1_000 + super::compiled::MAX_CACHED_MODULES as u32 {
        let wasm = distinct_wasm(n);
        let sha = sha256_hex(&wasm);
        ModuleHost::run(wasm, sha, GENEROUS, b"a".to_vec())
            .await
            .expect("a conforming module should run");
        assert!(super::compiled::cached_count() <= super::compiled::MAX_CACHED_MODULES);
    }

    assert!(
        !super::compiled::is_cached(&first_sha),
        "the first artifact must have been evicted once the bound was passed"
    );
}

#[tokio::test]
async fn a_module_that_imports_anything_is_refused() {
    let wasm = importing_wasm();
    let sha256 = sha256_hex(&wasm);

    let err = ModuleHost::run(wasm, sha256, GENEROUS, b"hi".to_vec())
        .await
        .expect_err("a module with an import must be refused");

    assert!(matches!(err, RunError::ImportsNotAllowed));
}

#[tokio::test]
async fn a_hash_mismatch_is_refused_before_anything_runs() {
    let wasm = echo_upper_wasm();

    let err = ModuleHost::run(wasm, "0".repeat(64), GENEROUS, b"hi".to_vec())
        .await
        .expect_err("a wrong sha256 must be refused");

    assert!(matches!(err, RunError::HashMismatch));
}

#[tokio::test]
async fn a_fuel_exhausting_module_is_killed_with_a_clean_error() {
    let wasm = fuel_burner_wasm();
    let sha256 = sha256_hex(&wasm);
    let tight_fuel = RunLimits {
        fuel: 10_000,
        ..GENEROUS
    };

    let err = ModuleHost::run(wasm, sha256, tight_fuel, b"hi".to_vec())
        .await
        .expect_err("an infinite loop must not hang the caller");

    assert!(matches!(err, RunError::ResourceLimited(_)));
}

#[tokio::test]
async fn compiling_a_module_does_not_count_against_its_wall_clock() {
    let wasm = slow_to_compile_echo_wasm(7);
    let sha256 = sha256_hex(&wasm);
    let tight_wall = RunLimits {
        wall: Duration::from_millis(20),
        ..GENEROUS
    };

    let out = ModuleHost::run(wasm, sha256, tight_wall, b"hi".to_vec())
        .await
        .expect("a run that is instant once compiled fits a short wall clock");

    assert_eq!(out, b"HI");
}

#[tokio::test]
async fn a_module_over_the_memory_cap_is_refused() {
    let wasm = memory_hog_wasm();
    let sha256 = sha256_hex(&wasm);
    let tiny_memory = RunLimits {
        memory_bytes: 64 * 1024,
        ..GENEROUS
    };

    let err = ModuleHost::run(wasm, sha256, tiny_memory, b"hi".to_vec())
        .await
        .expect_err("a module declaring more memory than the cap must be refused");

    assert!(matches!(err, RunError::Instantiate(_)));
}

/// A backstop below the fuel cap: even if fuel metering did not exist, the
/// wall-clock timeout alone must still return promptly rather than hang.
#[tokio::test]
async fn a_fuel_exhausting_module_still_returns_promptly_under_a_short_wall_clock() {
    let wasm = fuel_burner_wasm();
    let sha256 = sha256_hex(&wasm);
    let short_wall = RunLimits {
        wall: Duration::from_millis(200),
        ..GENEROUS
    };

    let started = std::time::Instant::now();
    let err = ModuleHost::run(wasm, sha256, short_wall, b"hi".to_vec())
        .await
        .expect_err("a runaway module must not hang the caller");
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(matches!(
        err,
        RunError::ResourceLimited(_) | RunError::Timeout
    ));
}

/// A valid `kv.store` set padded past the request cap with JSON whitespace:
/// without the cap it would be copied, parsed and honoured.
#[tokio::test]
async fn a_host_call_request_past_the_cap_is_not_honoured() {
    let request = r#"{"capability":"kv.store","op":"set","key":"k","value":"v"}"#;
    let padded = 200_000;
    let wasm = wat(&format!(
        r#"
        (module
            (import "slim" "host_call" (func $host_call (param i32 i32) (result i64)))
            (memory (export "memory") 8)
            (global $bump (mut i32) (i32.const 262144))
            (data (i32.const 1024) "{escaped}")
            (func (export "alloc") (param $len i32) (result i32)
                (local $ptr i32)
                (local.set $ptr (global.get $bump))
                (global.set $bump (i32.add (global.get $bump) (local.get $len)))
                (local.get $ptr))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (memory.fill (i32.const {pad_at}) (i32.const 32) (i32.const {pad_len}))
                (call $host_call (i32.const 1024) (i32.const {padded}))))
        "#,
        escaped = request.replace('"', "\\\""),
        pad_at = 1024 + request.len(),
        pad_len = padded - request.len(),
    ));
    let kv = Arc::new(InMemoryKv::default());
    let surface = CapabilitySurface::enabled(vec!["kv.store".to_owned()], "m", kv.clone());
    let output = ModuleHost::run_with_capabilities(
        wasm.clone(),
        sha256_hex(&wasm),
        GENEROUS,
        b"hi".to_vec(),
        surface,
    )
    .await
    .expect("the module itself runs to completion");
    assert!(
        output.is_empty(),
        "the oversized request got the empty response"
    );
    assert_eq!(
        super::kv::KvBackend::get(kv.as_ref(), "m", "k").unwrap(),
        None,
        "and was never honoured"
    );
}
