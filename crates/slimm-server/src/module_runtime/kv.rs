// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `kv.store`: the first reference capability (decision 0023), the safest one -
//! a key-value store private to a single module, touching nothing else.
//!
//! The capability's reviewable substance lives here: the five operations, the
//! per-request and per-store bounds, and the isolation between modules. Where
//! the bytes live is a [`KvBackend`]: [`InMemoryKv`] is the reference used by
//! tests, and `http::module_host::SqliteKv` is the durable one every live run
//! uses (decision 0023's addendum).
//!
//! Every path fails closed. A malformed request, an unknown op, an over-bound
//! key or value, a full store, or an exhausted per-run call budget all return a
//! clean `{ok:false,error}`; nothing here can reach another module's data or
//! anything outside the store.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde::Deserialize;
use serde_json::json;

/// Longest a key may be, in bytes.
pub const MAX_KEY_BYTES: usize = 256;
/// Largest a value may be, in bytes.
pub const MAX_VALUE_BYTES: usize = 4 * 1024;
/// Most entries one module may hold.
pub const MAX_ENTRIES: usize = 256;
/// Most total bytes (keys plus values) one module may hold.
pub const MAX_TOTAL_BYTES: usize = 64 * 1024;
/// Most `kv.store` calls one module run may make, so a single run cannot hammer
/// the store unbounded even within its fuel budget.
pub const MAX_CALLS_PER_RUN: u32 = 64;

/// Where a module's key-value pairs live, keyed by module id so no module can
/// see another's. The runtime holds this behind the capability gate; a durable
/// implementation is a future, reviewed step (decision 0023).
pub trait KvBackend: Send + Sync {
    fn get(&self, module_id: &str, key: &str) -> Result<Option<String>, KvError>;
    /// Stores `value` at `key`, or [`KvError::Full`] if it would take the
    /// module past [`MAX_ENTRIES`] or [`MAX_TOTAL_BYTES`].
    fn set(&self, module_id: &str, key: &str, value: &str) -> Result<(), KvError>;
    /// Stores `value` at `key` only if it now holds `expect` (absent when `None`), atomically,
    /// and says whether it did. A swap that would pass a cap is [`KvError::Full`].
    fn cas(
        &self,
        module_id: &str,
        key: &str,
        expect: Option<&str>,
        value: &str,
    ) -> Result<bool, KvError>;
    fn delete(&self, module_id: &str, key: &str) -> Result<(), KvError>;
    fn list(&self, module_id: &str) -> Result<Vec<String>, KvError>;
}

/// Why a `set` was refused by the backend (as opposed to a per-request bound
/// the handler checks first).
#[derive(Debug)]
pub enum KvError {
    Full,
    /// The backing store failed; the module sees a refusal, never the cause.
    Unavailable,
}

/// Dispatches one `kv.store` request against `backend` for `module_id`,
/// returning the UTF-8 JSON response. `calls_remaining` is this run's budget,
/// decremented per call and refused at zero.
pub fn handle(
    backend: &dyn KvBackend,
    module_id: &str,
    calls_remaining: &mut u32,
    request: &[u8],
) -> Vec<u8> {
    if *calls_remaining == 0 {
        return refusal("kv.store call budget for this run is exhausted");
    }
    *calls_remaining -= 1;

    let req: KvRequest = match serde_json::from_slice(request) {
        Ok(req) => req,
        Err(_) => return refusal("malformed kv.store request"),
    };

    match req.op.as_str() {
        "get" => match req.key {
            Some(key) => match backend.get(module_id, &key) {
                Ok(value) => ok(json!({ "value": value })),
                Err(_) => refusal("kv.store is unavailable"),
            },
            None => refusal("kv.store get needs a key"),
        },
        "set" => {
            let (Some(key), Some(value)) = (req.key, req.value) else {
                return refusal("kv.store set needs a key and a value");
            };
            if key.len() > MAX_KEY_BYTES {
                return refusal("kv.store key is too long");
            }
            if value.len() > MAX_VALUE_BYTES {
                return refusal("kv.store value is too large");
            }
            match backend.set(module_id, &key, &value) {
                Ok(()) => ok(json!({})),
                Err(KvError::Full) => refusal("kv.store is full for this module"),
                Err(KvError::Unavailable) => refusal("kv.store is unavailable"),
            }
        }
        "cas" => {
            let (Some(key), Some(value)) = (req.key, req.value) else {
                return refusal("kv.store cas needs a key and a value");
            };
            if key.len() > MAX_KEY_BYTES {
                return refusal("kv.store key is too long");
            }
            if value.len() > MAX_VALUE_BYTES {
                return refusal("kv.store value is too large");
            }
            match backend.cas(module_id, &key, req.expect.as_deref(), &value) {
                Ok(swapped) => ok(json!({ "swapped": swapped })),
                Err(KvError::Full) => refusal("kv.store is full for this module"),
                Err(KvError::Unavailable) => refusal("kv.store is unavailable"),
            }
        }
        "delete" => match req.key {
            Some(key) => match backend.delete(module_id, &key) {
                Ok(()) => ok(json!({})),
                Err(_) => refusal("kv.store is unavailable"),
            },
            None => refusal("kv.store delete needs a key"),
        },
        "list" => match backend.list(module_id) {
            Ok(keys) => ok(json!({ "keys": keys })),
            Err(_) => refusal("kv.store is unavailable"),
        },
        other => refusal(&format!("unknown kv.store op: {other}")),
    }
}

#[derive(Deserialize)]
struct KvRequest {
    op: String,
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    value: Option<String>,
    #[serde(default)]
    expect: Option<String>,
}

fn ok(mut body: serde_json::Value) -> Vec<u8> {
    if let Some(map) = body.as_object_mut() {
        map.insert("ok".to_owned(), json!(true));
    }
    serde_json::to_vec(&body).unwrap_or_else(|_| br#"{"ok":true}"#.to_vec())
}

fn refusal(message: &str) -> Vec<u8> {
    serde_json::to_vec(&json!({ "ok": false, "error": message }))
        .unwrap_or_else(|_| br#"{"ok":false,"error":"host error"}"#.to_vec())
}

/// The reference backend: an in-memory map per module, enforcing the entry and
/// total-byte caps. The durable backend (decision 0023) implements the same
/// trait against per-space storage; this proves the shape and the isolation.
#[derive(Default)]
pub struct InMemoryKv {
    modules: Mutex<BTreeMap<String, BTreeMap<String, String>>>,
}

impl KvBackend for InMemoryKv {
    fn get(&self, module_id: &str, key: &str) -> Result<Option<String>, KvError> {
        let modules = self.modules.lock().unwrap();
        Ok(modules.get(module_id).and_then(|m| m.get(key)).cloned())
    }

    fn set(&self, module_id: &str, key: &str, value: &str) -> Result<(), KvError> {
        let mut modules = self.modules.lock().unwrap();
        let store = modules.entry(module_id.to_owned()).or_default();
        // Overwriting an existing key spends no new entry; a new key must fit both caps.
        let replacing = store.get(key);
        let new_entries = store.len() + usize::from(replacing.is_none());
        let old_bytes: usize = replacing.map_or(0, |v| key.len() + v.len());
        let total_bytes = current_bytes(store) - old_bytes + key.len() + value.len();
        if new_entries > MAX_ENTRIES || total_bytes > MAX_TOTAL_BYTES {
            return Err(KvError::Full);
        }
        store.insert(key.to_owned(), value.to_owned());
        Ok(())
    }

    fn cas(
        &self,
        module_id: &str,
        key: &str,
        expect: Option<&str>,
        value: &str,
    ) -> Result<bool, KvError> {
        let mut modules = self.modules.lock().unwrap();
        let store = modules.entry(module_id.to_owned()).or_default();
        if store.get(key).map(String::as_str) != expect {
            return Ok(false);
        }
        let old_bytes = store.get(key).map_or(0, |v| key.len() + v.len());
        let new_entries = store.len() + usize::from(expect.is_none());
        let total_bytes = current_bytes(store) - old_bytes + key.len() + value.len();
        if new_entries > MAX_ENTRIES || total_bytes > MAX_TOTAL_BYTES {
            return Err(KvError::Full);
        }
        store.insert(key.to_owned(), value.to_owned());
        Ok(true)
    }

    fn delete(&self, module_id: &str, key: &str) -> Result<(), KvError> {
        let mut modules = self.modules.lock().unwrap();
        if let Some(store) = modules.get_mut(module_id) {
            store.remove(key);
        }
        Ok(())
    }

    fn list(&self, module_id: &str) -> Result<Vec<String>, KvError> {
        let modules = self.modules.lock().unwrap();
        Ok(modules
            .get(module_id)
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default())
    }
}

fn current_bytes(store: &BTreeMap<String, String>) -> usize {
    store.iter().map(|(k, v)| k.len() + v.len()).sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(bytes: Vec<u8>) -> String {
        String::from_utf8(bytes).unwrap()
    }

    fn budget() -> u32 {
        MAX_CALLS_PER_RUN
    }

    #[test]
    fn set_then_get_round_trips() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        text(handle(
            &kv,
            "m",
            &mut calls,
            br#"{"op":"set","key":"a","value":"1"}"#,
        ));
        let out = text(handle(&kv, "m", &mut calls, br#"{"op":"get","key":"a"}"#));
        assert!(out.contains(r#""value":"1""#), "{out}");
    }

    #[test]
    fn get_of_a_missing_key_is_null_not_an_error() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        let out = text(handle(
            &kv,
            "m",
            &mut calls,
            br#"{"op":"get","key":"nope"}"#,
        ));
        assert!(
            out.contains(r#""ok":true"#) && out.contains(r#""value":null"#),
            "{out}"
        );
    }

    #[test]
    fn one_module_cannot_see_anothers_keys() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        handle(
            &kv,
            "a",
            &mut calls,
            br#"{"op":"set","key":"secret","value":"x"}"#,
        );
        let out = text(handle(
            &kv,
            "b",
            &mut calls,
            br#"{"op":"get","key":"secret"}"#,
        ));
        assert!(
            out.contains(r#""value":null"#),
            "module b must not read module a: {out}"
        );
        let listed = text(handle(&kv, "b", &mut calls, br#"{"op":"list"}"#));
        assert!(listed.contains(r#""keys":[]"#), "{listed}");
    }

    #[test]
    fn an_oversized_key_or_value_is_refused() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        let big_key = format!(
            r#"{{"op":"set","key":"{}","value":"x"}}"#,
            "k".repeat(MAX_KEY_BYTES + 1)
        );
        assert!(text(handle(&kv, "m", &mut calls, big_key.as_bytes())).contains("key is too long"));
        let big_val = format!(
            r#"{{"op":"set","key":"k","value":"{}"}}"#,
            "v".repeat(MAX_VALUE_BYTES + 1)
        );
        assert!(
            text(handle(&kv, "m", &mut calls, big_val.as_bytes())).contains("value is too large")
        );
    }

    #[test]
    fn the_store_fills_at_the_entry_cap() {
        let kv = InMemoryKv::default();
        let mut calls = u32::MAX;
        for i in 0..MAX_ENTRIES {
            let req = format!(r#"{{"op":"set","key":"k{i}","value":"v"}}"#);
            assert!(text(handle(&kv, "m", &mut calls, req.as_bytes())).contains(r#""ok":true"#));
        }
        let over = text(handle(
            &kv,
            "m",
            &mut calls,
            br#"{"op":"set","key":"one-more","value":"v"}"#,
        ));
        assert!(over.contains("is full"), "{over}");
        // Overwriting an existing key still works at the cap.
        assert!(
            text(handle(
                &kv,
                "m",
                &mut calls,
                br#"{"op":"set","key":"k0","value":"w"}"#
            ))
            .contains(r#""ok":true"#)
        );
    }

    /// The bounds are inclusive: a key or value exactly at its cap is fine, one
    /// byte over is not.
    #[test]
    fn a_key_or_value_exactly_at_its_bound_is_accepted() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        let key = format!(
            r#"{{"op":"set","key":"{}","value":"x"}}"#,
            "k".repeat(MAX_KEY_BYTES)
        );
        assert!(text(handle(&kv, "m", &mut calls, key.as_bytes())).contains(r#""ok":true"#));
        let value = format!(
            r#"{{"op":"set","key":"v","value":"{}"}}"#,
            "v".repeat(MAX_VALUE_BYTES)
        );
        assert!(text(handle(&kv, "m", &mut calls, value.as_bytes())).contains(r#""ok":true"#));
    }

    /// Bytes are counted as key plus value, filled to exactly the cap, and a
    /// replacement is charged only for its difference: overwriting at the cap
    /// with the same size fits, with one more byte does not, and deleting frees
    /// the room a new key then takes.
    #[test]
    fn the_store_fills_at_the_byte_cap_and_a_replacement_costs_only_its_difference() {
        let kv = InMemoryKv::default();
        let per_entry = MAX_VALUE_BYTES;
        let value = "v".repeat(per_entry - 1);
        let entries = MAX_TOTAL_BYTES / per_entry;
        assert_eq!(
            entries * per_entry,
            MAX_TOTAL_BYTES,
            "the fixture fills the cap exactly"
        );
        let keys: Vec<String> = (0..entries)
            .map(|i| char::from(b'a' + i as u8).to_string())
            .collect();
        for key in &keys {
            kv.set("m", key, &value)
                .expect("fits until exactly the cap");
        }

        assert!(
            matches!(kv.set("m", "z", ""), Err(KvError::Full)),
            "one byte over the cap"
        );
        let last = keys.last().unwrap();
        assert!(
            kv.set("m", last, &value).is_ok(),
            "same size in place costs nothing"
        );
        assert!(
            matches!(kv.set("m", last, &format!("{value}+")), Err(KvError::Full)),
            "one byte larger in place is charged the difference"
        );

        kv.delete("m", last).unwrap();
        assert!(kv.set("m", "z", &value).is_ok(), "a delete frees its bytes");
        let listed = kv.list("m").unwrap();
        assert_eq!(listed.len(), entries);
        assert!(listed.contains(&"z".to_owned()) && !listed.contains(last));
    }

    #[test]
    fn the_per_run_call_budget_is_enforced() {
        let kv = InMemoryKv::default();
        let mut calls = 1;
        assert!(text(handle(&kv, "m", &mut calls, br#"{"op":"list"}"#)).contains(r#""ok":true"#));
        let out = text(handle(&kv, "m", &mut calls, br#"{"op":"list"}"#));
        assert!(
            out.contains("budget") && out.contains(r#""ok":false"#),
            "{out}"
        );
    }

    #[test]
    fn an_unknown_op_or_malformed_request_is_refused() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        assert!(
            text(handle(&kv, "m", &mut calls, br#"{"op":"drop"}"#)).contains("unknown kv.store op")
        );
        assert!(text(handle(&kv, "m", &mut calls, b"not json")).contains("malformed"));
    }

    #[test]
    fn cas_swaps_only_when_the_expectation_holds() {
        let kv = InMemoryKv::default();
        let mut calls = budget();
        let mut run = |req: &str| text(handle(&kv, "m", &mut calls, req.as_bytes()));
        let first = run(r#"{"op":"cas","key":"n","value":"1"}"#);
        assert!(first.contains(r#""swapped":true"#), "{first}");
        let again = run(r#"{"op":"cas","key":"n","value":"2"}"#);
        assert!(again.contains(r#""swapped":false"#), "{again}");
        let stale = run(r#"{"op":"cas","key":"n","expect":"0","value":"2"}"#);
        assert!(stale.contains(r#""swapped":false"#), "{stale}");
        let fresh = run(r#"{"op":"cas","key":"n","expect":"1","value":"2"}"#);
        assert!(fresh.contains(r#""swapped":true"#), "{fresh}");
        assert!(run(r#"{"op":"get","key":"n"}"#).contains(r#""value":"2""#));
    }

    #[test]
    fn two_concurrent_cas_writers_swap_exactly_once() {
        let kv = std::sync::Arc::new(InMemoryKv::default());
        kv.set("m", "n", "0").unwrap();
        let wins: usize = (0..8)
            .map(|i| {
                let kv = std::sync::Arc::clone(&kv);
                std::thread::spawn(move || kv.cas("m", "n", Some("0"), &format!("w{i}")).unwrap())
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|t| usize::from(t.join().unwrap()))
            .sum();
        assert_eq!(wins, 1);
    }

    #[test]
    fn cas_respects_the_caps() {
        let kv = InMemoryKv::default();
        for i in 0..MAX_ENTRIES {
            kv.set("m", &format!("k{i}"), "v").unwrap();
        }
        assert!(matches!(
            kv.cas("m", "one-more", None, "v"),
            Err(KvError::Full)
        ));
    }
}
