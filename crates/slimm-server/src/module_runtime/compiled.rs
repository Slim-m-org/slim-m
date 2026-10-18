// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The one wasmi [`Engine`] every run shares, and a content-addressed cache of
//! compiled [`Module`]s in front of it.
//!
//! Compiling a module (parse, validate, translate) is the expensive part of a
//! run and is a pure function of the artifact bytes; the host has already
//! proved those bytes match the sha256 recorded at install before it gets
//! here. Keying the cache by that verified digest therefore changes nothing a
//! module can observe: a fresh `Store` and `Instance` are still built per run,
//! so no memory, globals, or fuel ever carry over between calls. Only the
//! translation work is reused.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use wasmi::{Config, Engine, Module};

use super::host::RunError;

/// How many distinct artifacts stay compiled at once. A deployment installs a
/// handful of modules, so this is well above steady state; when it is
/// exceeded the whole cache is dropped rather than tracking recency, since a
/// miss only costs one recompile.
pub(super) const MAX_CACHED_MODULES: usize = 16;

fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let mut config = Config::default();
        config.consume_fuel(true);
        Engine::new(&config)
    })
}

fn cache() -> &'static Mutex<HashMap<String, Module>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Module>>> = OnceLock::new();
    CACHE.get_or_init(Mutex::default)
}

/// The compiled form of an artifact already verified under `sha256`, if cached.
pub(super) fn cached_module(sha256: &str) -> Option<Module> {
    cache().lock().ok().and_then(|c| c.get(sha256).cloned())
}

/// The compiled form of `wasm`, whose verified sha256 is `sha256`, compiling
/// it on the first sight of that digest and reusing it after.
pub(super) fn compiled_module(sha256: &str, wasm: &[u8]) -> Result<Module, RunError> {
    if let Some(module) = cache().lock().ok().and_then(|c| c.get(sha256).cloned()) {
        return Ok(module);
    }
    let module = Module::new(engine(), wasm)
        .map_err(|e| RunError::Instantiate(format!("invalid wasm module: {e}")))?;
    if let Ok(mut cache) = cache().lock() {
        remember(&mut cache, sha256, module.clone());
    }
    Ok(module)
}

/// Adds `module` under `sha256`, dropping the whole cache first once it holds
/// [`MAX_CACHED_MODULES`] entries: a miss costs one recompile, so wholesale
/// eviction is cheaper than tracking recency for a handful of modules.
fn remember(cache: &mut HashMap<String, Module>, sha256: &str, module: Module) {
    if cache.len() >= MAX_CACHED_MODULES {
        cache.clear();
    }
    cache.insert(sha256.to_owned(), module);
}

/// The engine a compiled module belongs to; a run's `Store` must be built on
/// the same one.
pub(super) fn shared_engine() -> &'static Engine {
    engine()
}

#[cfg(test)]
pub(super) fn cached_count() -> usize {
    cache().lock().map(|c| c.len()).unwrap_or(0)
}

#[cfg(test)]
pub(super) fn is_cached(sha256: &str) -> bool {
    cache()
        .lock()
        .map(|c| c.contains_key(sha256))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn module(n: usize) -> Module {
        let wasm = wat::parse_str(format!("(module (global i32 (i32.const {n})))")).unwrap();
        Module::new(engine(), &wasm).unwrap()
    }

    /// Entries accumulate up to the bound and are dropped wholesale one past
    /// it: nothing is evicted early, and nothing survives the clear except the
    /// entry that triggered it.
    #[test]
    fn remember_keeps_every_entry_up_to_the_bound_then_starts_over() {
        let mut cache = HashMap::new();
        for n in 0..MAX_CACHED_MODULES {
            remember(&mut cache, &n.to_string(), module(n));
            assert_eq!(cache.len(), n + 1, "nothing is evicted below the bound");
        }
        assert!(cache.contains_key("0"));

        remember(&mut cache, "one-more", module(MAX_CACHED_MODULES));
        assert_eq!(cache.len(), 1, "the bound drops everything before it");
        assert!(cache.contains_key("one-more"));
        assert!(!cache.contains_key("0"));
    }
}
