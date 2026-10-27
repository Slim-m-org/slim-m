// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Hand-written WAT fixtures shared by the module host tests.

use std::time::Duration;

use super::RunLimits;

pub(super) const GENEROUS: RunLimits = RunLimits {
    memory_bytes: 4 * 1024 * 1024,
    fuel: 50_000_000,
    wall: Duration::from_millis(500),
};

pub(super) fn wat(text: &str) -> Vec<u8> {
    wat::parse_str(text).expect("fixture WAT must parse")
}

/// A bump allocator plus a `run` that ASCII-uppercases its input in place and
/// returns the same region back - proves the alloc/write/call/read plumbing
/// end to end without any JSON logic in the fixture itself.
pub(super) fn echo_upper_wasm() -> Vec<u8> {
    wat(ECHO_UPPER_WAT)
}

pub(super) const ECHO_UPPER_WAT: &str = r#"
        (module
            (memory (export "memory") 1)
            (global $bump (mut i32) (i32.const 1024))
            (func (export "alloc") (param $len i32) (result i32)
                (local $ptr i32)
                (local.set $ptr (global.get $bump))
                (global.set $bump (i32.add (global.get $bump) (local.get $len)))
                (local.get $ptr))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32)
                (local $b i32)
                (block $done
                    (loop $loop
                        (br_if $done (i32.ge_u (local.get $i) (local.get $in_len)))
                        (local.set $b (i32.load8_u (i32.add (local.get $in_ptr) (local.get $i))))
                        (if (i32.and
                                (i32.ge_u (local.get $b) (i32.const 97))
                                (i32.le_u (local.get $b) (i32.const 122)))
                            (then (local.set $b (i32.sub (local.get $b) (i32.const 32)))))
                        (i32.store8 (i32.add (local.get $in_ptr) (local.get $i)) (local.get $b))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $loop)))
                (i64.or
                    (i64.shl (i64.extend_i32_u (local.get $in_ptr)) (i64.const 32))
                    (i64.extend_i32_u (local.get $in_len)))))
    "#;

/// Otherwise ABI-conformant, but declares a wasm import - the one shape the
/// host must refuse outright, per the module ABI's "no ambient authority"
/// rule.
pub(super) fn importing_wasm() -> Vec<u8> {
    wat(r#"
        (module
            (import "env" "log" (func $log (param i32)))
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64) (i64.const 0)))
    "#)
}

/// `run` never returns: an unconditional loop back to its own start, burning
/// fuel forever.
pub(super) fn fuel_burner_wasm() -> Vec<u8> {
    wat(r#"
        (module
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (loop $l (br $l))
                (i64.const 0)))
    "#)
}

/// Declares a minimum memory of 2 pages (128 KiB), deliberately larger than
/// the 1-page cap the memory-cap test configures, so instantiation itself is
/// refused before `run` is ever reachable.
pub(super) fn memory_hog_wasm() -> Vec<u8> {
    wat(r#"
        (module
            (memory (export "memory") 2)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64) (i64.const 0)))
    "#)
}

/// ABI-conformant and declares the single `slim.host_call` import (the only
/// import a capability-using module may have): a bump allocator so the host can
/// write the response back, the `request` staged at offset 1024, and a `run`
/// that calls `host_call` on it and returns its packed result verbatim - so the
/// host's response comes straight back out as the module's output.
pub(super) fn host_call_wasm(request: &str) -> Vec<u8> {
    let escaped: String = request
        .chars()
        .flat_map(|c| match c {
            '"' => vec!['\\', '"'],
            '\\' => vec!['\\', '\\'],
            other => vec![other],
        })
        .collect();
    wat(&format!(
        r#"
        (module
            (import "slim" "host_call" (func $host_call (param i32 i32) (result i64)))
            (memory (export "memory") 1)
            (global $bump (mut i32) (i32.const 8192))
            (data (i32.const 1024) "{escaped}")
            (func (export "alloc") (param $len i32) (result i32)
                (local $ptr i32)
                (local.set $ptr (global.get $bump))
                (global.set $bump (i32.add (global.get $bump) (local.get $len)))
                (local.get $ptr))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (call $host_call (i32.const 1024) (i32.const {len}))))
        "#,
        len = request.len()
    ))
}

/// ABI-conformant, but `run` claims its response is 4 GiB long at offset 0 -
/// far beyond the single 64 KiB page it actually has. The host must refuse
/// that region, not allocate it.
pub(super) fn oversized_output_wasm() -> Vec<u8> {
    wat(r#"
        (module
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (i64.const 0xFFFFFFFF)))
    "#)
}

/// Declares `slim.host_call` and asks the host to read a 2 GiB request from
/// offset 0 of its single page, returning `host_call`'s result verbatim.
pub(super) fn oversized_host_call_wasm() -> Vec<u8> {
    wat(r#"
        (module
            (import "slim" "host_call" (func $host_call (param i32 i32) (result i64)))
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (call $host_call (i32.const 0) (i32.const 0x7FFFFFFF))))
    "#)
}

/// [`echo_upper_wasm`] with a distinct global, so each `n` compiles to different
/// bytes and therefore a different cache entry.
pub(super) fn distinct_wasm(n: u32) -> Vec<u8> {
    let base = String::from_utf8(echo_upper_wasm_source()).unwrap();
    wat(&base.replace("(module", &format!("(module (global i32 (i32.const {n}))")))
}

pub(super) fn echo_upper_wasm_source() -> Vec<u8> {
    ECHO_UPPER_WAT.as_bytes().to_vec()
}

pub(super) fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    crate::media::to_hex(&Sha256::digest(bytes))
}

/// The echo module plus a large function nothing calls: slow to compile,
/// instant to run. `salt` makes each copy a fresh digest the cache has not seen.
pub(super) fn slow_to_compile_echo_wasm(salt: u32) -> Vec<u8> {
    let padding: String = (0..120_000)
        .map(|i| format!("(drop (i32.add (i32.const {i}) (i32.const {salt})))"))
        .collect();
    let source =
        ECHO_UPPER_WAT.replacen("(module", &format!("(module (func $padding {padding})"), 1);
    wat(&source)
}
