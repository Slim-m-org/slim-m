// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Wasm fixtures for `crate::module_runtime`, shared by every integration
//! test that installs a module and then actually invokes it. Each is
//! hand-written WAT, compiled to wasm bytes at test time so its exact
//! behavior is readable here rather than shipped as an opaque checked-in
//! binary. `crates/slimm-server/src/module_runtime/tests.rs` has its own
//! smaller copies for the host's own unit tests; these are for the HTTP and
//! response-contract layers, which need a module that actually answers the
//! ABI's JSON shape.

use sha2::{Digest, Sha256};

/// A module that ignores its input and always answers with exactly `bytes`
/// at the ABI level - the primitive every other fixture here is built from.
#[allow(dead_code)]
pub fn canned_raw_wasm(bytes: &[u8]) -> Vec<u8> {
    let data = escape_wat_string(bytes);
    let len = bytes.len();
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (data (i32.const 1024) "{data}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 8192))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (i64.or (i64.shl (i64.const 1024) (i64.const 32)) (i64.const {len}))))"#
    );
    wat::parse_str(&text).expect("canned wasm fixture must parse")
}

/// A module that always answers `{"ok":true,"output":"<output>"}"`,
/// regardless of what it was asked. `output` must not contain a `"` or `\`.
#[allow(dead_code)]
pub fn canned_ok_wasm(output: &str) -> Vec<u8> {
    canned_raw_wasm(format!(r#"{{"ok":true,"output":"{output}"}}"#).as_bytes())
}

/// A module that answers `{"ok":true,"output":"<its own request>"}`, with every
/// `"` and `\` in the request replaced by `'` so the response stays valid JSON.
#[allow(dead_code)]
pub fn echo_request_wasm() -> Vec<u8> {
    let prefix = r#"{"ok":true,"output":""#;
    let data = escape_wat_string(prefix.as_bytes());
    let plen = prefix.len();
    let tail = plen + 2;
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (data (i32.const 1024) "{data}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 8192))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32) (local $b i32) (local $out i32)
                (local.set $out (i32.add (i32.const 1024) (i32.const {plen})))
                (block $done
                    (loop $loop
                        (br_if $done (i32.ge_u (local.get $i) (local.get $in_len)))
                        (local.set $b (i32.load8_u (i32.add (local.get $in_ptr) (local.get $i))))
                        (if (i32.or (i32.eq (local.get $b) (i32.const 34))
                                    (i32.eq (local.get $b) (i32.const 92)))
                            (then (local.set $b (i32.const 39))))
                        (i32.store8 (i32.add (local.get $out) (local.get $i)) (local.get $b))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $loop)))
                (i32.store8 (i32.add (local.get $out) (local.get $in_len)) (i32.const 34))
                (i32.store8 (i32.add (local.get $out) (i32.add (local.get $in_len) (i32.const 1))) (i32.const 125))
                (i64.or (i64.shl (i64.const 1024) (i64.const 32))
                    (i64.extend_i32_u (i32.add (local.get $in_len) (i32.const {tail}))))))"#
    );
    wat::parse_str(&text).expect("echo-request wasm fixture must parse")
}

/// `run` never returns: an unconditional loop back to its own start, burning
/// fuel forever. Proves a route driving `ModuleHost` end to end still
/// answers cleanly rather than hanging or 500ing.
#[allow(dead_code)]
pub fn fuel_burner_wasm() -> Vec<u8> {
    wat::parse_str(
        r#"(module
            (memory (export "memory") 1)
            (func (export "alloc") (param $len i32) (result i32) (i32.const 0))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (loop $l (br $l))
                (i64.const 0)))"#,
    )
    .expect("fuel-burner wasm fixture must parse")
}

#[allow(dead_code)]
pub fn sha256_hex(bytes: &[u8]) -> String {
    slimm_server::media::to_hex(&Sha256::digest(bytes))
}

/// A module that imports `slim.host_call`, sends `request` through it `count`
/// times, and answers with the last host response wrapped as its own output
/// (`"` and `\` in it become `'`, so the caller reads it as a plain string).
/// A `@@` in `request` is overwritten each round with the two-digit round
/// number, so one run can write distinct keys.
#[allow(dead_code)]
pub fn host_call_loop_wasm(request: &str, count: u32) -> Vec<u8> {
    let data = escape_wat_string(request.as_bytes());
    let len = request.len();
    let patch = request.find("@@").map_or(String::new(), |at| {
        let tens = 1024 + at;
        let ones = tens + 1;
        format!(
            "(i32.store8 (i32.const {tens}) (i32.add (i32.const 48) (i32.div_u (local.get $i) (i32.const 10))))
             (i32.store8 (i32.const {ones}) (i32.add (i32.const 48) (i32.rem_u (local.get $i) (i32.const 10))))"
        )
    });
    let prefix = r#"{"ok":true,"output":""#;
    let prefix_data = escape_wat_string(prefix.as_bytes());
    let plen = prefix.len();
    let text = format!(
        r#"(module
            (import "slim" "host_call" (func $host_call (param i32 i32) (result i64)))
            (memory (export "memory") 2)
            (data (i32.const 1024) "{data}")
            (data (i32.const 24576) "{prefix_data}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 16384))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32) (local $j i32) (local $b i32)
                (local $packed i64) (local $ptr i32) (local $rlen i32)
                (loop $rounds
                    {patch}
                    (local.set $packed (call $host_call (i32.const 1024) (i32.const {len})))
                    (local.set $i (i32.add (local.get $i) (i32.const 1)))
                    (br_if $rounds (i32.lt_u (local.get $i) (i32.const {count}))))
                (local.set $ptr (i32.wrap_i64 (i64.shr_u (local.get $packed) (i64.const 32))))
                (local.set $rlen (i32.wrap_i64 (i64.and (local.get $packed) (i64.const 0xffffffff))))
                (block $done
                    (loop $copy
                        (br_if $done (i32.ge_u (local.get $j) (local.get $rlen)))
                        (local.set $b (i32.load8_u (i32.add (local.get $ptr) (local.get $j))))
                        (if (i32.or (i32.eq (local.get $b) (i32.const 34))
                                    (i32.eq (local.get $b) (i32.const 92)))
                            (then (local.set $b (i32.const 39))))
                        (i32.store8 (i32.add (i32.const {out}) (local.get $j)) (local.get $b))
                        (local.set $j (i32.add (local.get $j) (i32.const 1)))
                        (br $copy)))
                (i32.store8 (i32.add (i32.const {out}) (local.get $rlen)) (i32.const 34))
                (i32.store8 (i32.add (i32.const {out}) (i32.add (local.get $rlen) (i32.const 1))) (i32.const 125))
                (i64.or (i64.shl (i64.const 24576) (i64.const 32))
                    (i64.extend_i32_u (i32.add (local.get $rlen) (i32.const {tail}))))))"#,
        out = 24576 + plen,
        tail = plen + 2,
    );
    wat::parse_str(&text).expect("host-call loop wasm fixture must parse")
}

/// Escapes `bytes` as a WAT string-literal body: only `\` and `"` need it for
/// content in this file's own callers, all of which are ASCII with no quotes
/// or backslashes of their own, but this stays correct if that ever changes.
fn escape_wat_string(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len());
    for &b in bytes {
        match b {
            b'\\' => out.push_str("\\\\"),
            b'"' => out.push_str("\\\""),
            0x20..=0x7e => out.push(b as char),
            other => out.push_str(&format!("\\{other:02x}")),
        }
    }
    out
}

/// A module that answers every run with `{"ok":true,"output":<slot_response as text>}`,
/// the shape a `@slot` run returns.
#[allow(dead_code)]
pub fn canned_slot_wasm(slot_response: &serde_json::Value) -> Vec<u8> {
    let wire = serde_json::json!({ "ok": true, "output": slot_response.to_string() });
    canned_raw_wasm(wire.to_string().as_bytes())
}
