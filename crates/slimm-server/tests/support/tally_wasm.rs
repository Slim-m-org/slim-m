// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A stateful surface module for tests: every run answers a scene whose
//! `state` is the `state` it was handed plus one `x`, after a short spin so
//! concurrent presses really overlap. The count of `x` is the presses applied.

const PREFIX: &str = r#"{"ok":true,"output":"{\"$slim\":\"scene/1\",\"ops\":[],\"state\":\""#;

fn wat_literal(text: &str) -> String {
    text.replace('\\', "\\\\").replace('"', "\\\"")
}

pub fn tally_wasm() -> Vec<u8> {
    let prefix = wat_literal(PREFIX);
    let plen = PREFIX.len();
    let text = format!(
        r#"(module
            (memory (export "memory") 1)
            (data (i32.const 512) "\\\"state\\\":\\\"")
            (data (i32.const 1024) "{prefix}")
            (func (export "alloc") (param $len i32) (result i32) (i32.const 8192))
            (func $matches (param $p i32) (result i32) (local $k i32)
                (loop $l
                    (if (i32.ne (i32.load8_u (i32.add (local.get $p) (local.get $k)))
                                (i32.load8_u (i32.add (i32.const 512) (local.get $k))))
                        (then (return (i32.const 0))))
                    (local.set $k (i32.add (local.get $k) (i32.const 1)))
                    (br_if $l (i32.lt_u (local.get $k) (i32.const 12))))
                (i32.const 1))
            (func (export "run") (param $in_ptr i32) (param $in_len i32) (result i64)
                (local $i i32) (local $o i32) (local $b i32) (local $spin i32)
                (local.set $o (i32.add (i32.const 1024) (i32.const {plen})))
                (block $done
                    (loop $scan
                        (br_if $done (i32.gt_u (i32.add (local.get $i) (i32.const 12)) (local.get $in_len)))
                        (if (call $matches (i32.add (local.get $in_ptr) (local.get $i)))
                            (then
                                (local.set $i (i32.add (local.get $i) (i32.const 12)))
                                (block $copied
                                    (loop $copy
                                        (br_if $copied (i32.ge_u (local.get $i) (local.get $in_len)))
                                        (local.set $b (i32.load8_u (i32.add (local.get $in_ptr) (local.get $i))))
                                        (br_if $copied (i32.eq (local.get $b) (i32.const 92)))
                                        (i32.store8 (local.get $o) (local.get $b))
                                        (local.set $o (i32.add (local.get $o) (i32.const 1)))
                                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                                        (br $copy)))
                                (br $done)))
                        (local.set $i (i32.add (local.get $i) (i32.const 1)))
                        (br $scan)))
                (i32.store8 (local.get $o) (i32.const 120))
                (i32.store8 (i32.add (local.get $o) (i32.const 1)) (i32.const 92))
                (i32.store8 (i32.add (local.get $o) (i32.const 2)) (i32.const 34))
                (i32.store8 (i32.add (local.get $o) (i32.const 3)) (i32.const 125))
                (i32.store8 (i32.add (local.get $o) (i32.const 4)) (i32.const 34))
                (i32.store8 (i32.add (local.get $o) (i32.const 5)) (i32.const 125))
                (loop $wait
                    (local.set $spin (i32.add (local.get $spin) (i32.const 1)))
                    (br_if $wait (i32.lt_u (local.get $spin) (i32.const 300000))))
                (i64.or (i64.shl (i64.const 1024) (i64.const 32))
                    (i64.extend_i32_u (i32.sub (i32.add (local.get $o) (i32.const 6)) (i32.const 1024))))))"#
    );
    wat::parse_str(&text).expect("tally wasm fixture must parse")
}
