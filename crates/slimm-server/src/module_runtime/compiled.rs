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
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError};

use wasmi::{Config, Engine, Module};

use super::host::RunError;

/// How many distinct artifacts stay compiled at once. The Dock registry lists
/// nearly thirty modules, so this leaves room to install the lot and more;
/// past it the least recently run artifact is dropped, one at a time.
pub(super) const MAX_CACHED_MODULES: usize = 64;

fn engine() -> &'static Engine {
    static ENGINE: OnceLock<Engine> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let mut config = Config::default();
        config.consume_fuel(true);
        Engine::new(&config)
    })
}

fn shared() -> &'static Compiled {
    static COMPILED: OnceLock<Compiled> = OnceLock::new();
    COMPILED.get_or_init(Compiled::default)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The compiled form of an artifact already verified under `sha256`, if cached.
pub(super) fn cached_module(sha256: &str) -> Option<Module> {
    shared().cached(sha256)
}

/// The compiled form of `wasm`, whose verified sha256 is `sha256`, compiling
/// it on the first sight of that digest and reusing it after.
pub(super) fn compiled_module(sha256: &str, wasm: &[u8]) -> Result<Module, RunError> {
    shared().get_or_compile(sha256, || {
        Module::new(engine(), wasm)
            .map_err(|e| RunError::Instantiate(format!("invalid wasm module: {e}")))
    })
}

struct Entry {
    module: Module,
    last_used: u64,
}

/// Compiled modules by verified digest, evicting the least recently used one when full.
#[derive(Default)]
struct Cache {
    entries: HashMap<String, Entry>,
    clock: u64,
}

impl Cache {
    fn get(&mut self, sha256: &str) -> Option<Module> {
        self.clock += 1;
        let entry = self.entries.get_mut(sha256)?;
        entry.last_used = self.clock;
        Some(entry.module.clone())
    }

    fn insert(&mut self, sha256: &str, module: Module) {
        if !self.entries.contains_key(sha256) && self.entries.len() >= MAX_CACHED_MODULES {
            self.evict_least_recently_used();
        }
        self.clock += 1;
        let last_used = self.clock;
        self.entries
            .insert(sha256.to_owned(), Entry { module, last_used });
    }

    fn evict_least_recently_used(&mut self) {
        let oldest = self
            .entries
            .iter()
            .min_by_key(|(_, entry)| entry.last_used)
            .map(|(sha256, _)| sha256.clone());
        if let Some(sha256) = oldest {
            tracing::debug!(%sha256, "compiled module cache is full, dropping the least recently used");
            self.entries.remove(&sha256);
        }
    }
}

/// The cache plus one lock per digest being compiled, so concurrent misses on
/// the same artifact compile it once.
#[derive(Default)]
struct Compiled {
    cache: Mutex<Cache>,
    flights: Mutex<HashMap<String, Arc<Mutex<()>>>>,
}

impl Compiled {
    fn cached(&self, sha256: &str) -> Option<Module> {
        lock(&self.cache).get(sha256)
    }

    fn get_or_compile(
        &self,
        sha256: &str,
        compile: impl FnOnce() -> Result<Module, RunError>,
    ) -> Result<Module, RunError> {
        if let Some(module) = self.cached(sha256) {
            return Ok(module);
        }
        let flight = Arc::clone(lock(&self.flights).entry(sha256.to_owned()).or_default());
        let _turn = lock(&flight);
        let result = match self.cached(sha256) {
            Some(module) => Ok(module),
            None => compile().inspect(|module| lock(&self.cache).insert(sha256, module.clone())),
        };
        lock(&self.flights).remove(sha256);
        result
    }
}

/// The engine a compiled module belongs to; a run's `Store` must be built on
/// the same one.
pub(super) fn shared_engine() -> &'static Engine {
    engine()
}

#[cfg(test)]
pub(super) fn cached_count() -> usize {
    lock(&shared().cache).entries.len()
}

#[cfg(test)]
pub(super) fn is_cached(sha256: &str) -> bool {
    lock(&shared().cache).entries.contains_key(sha256)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn module(n: usize) -> Module {
        let wasm = wat::parse_str(format!("(module (global i32 (i32.const {n})))")).unwrap();
        Module::new(engine(), &wasm).unwrap()
    }

    /// Past the bound one entry goes, the one nobody ran lately, and a run in
    /// between keeps its artifact.
    #[test]
    fn a_full_cache_drops_only_the_least_recently_used_entry() {
        let mut cache = Cache::default();
        for n in 0..MAX_CACHED_MODULES {
            cache.insert(&n.to_string(), module(n));
            assert_eq!(cache.entries.len(), n + 1, "nothing goes below the bound");
        }
        assert!(cache.get("0").is_some(), "running 0 makes 1 the oldest");

        cache.insert("one-more", module(MAX_CACHED_MODULES));
        assert_eq!(cache.entries.len(), MAX_CACHED_MODULES);
        assert!(cache.entries.contains_key("0"));
        assert!(cache.entries.contains_key("one-more"));
        assert!(!cache.entries.contains_key("1"));
    }

    /// A working set larger than the old bound of 16 stays compiled.
    #[test]
    fn a_working_set_past_sixteen_modules_keeps_hitting() {
        let compiled = Compiled::default();
        for round in 0..2 {
            for n in 0..20 {
                let key = n.to_string();
                let built = std::cell::Cell::new(false);
                compiled
                    .get_or_compile(&key, || {
                        built.set(true);
                        Ok(module(n))
                    })
                    .unwrap();
                assert_eq!(built.get(), round == 0, "module {n}, round {round}");
            }
        }
    }

    /// Concurrent misses on one digest compile it once and share the result.
    #[test]
    fn concurrent_misses_on_one_digest_compile_it_once() {
        let compiled = Compiled::default();
        let compiles = std::sync::atomic::AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..8 {
                scope.spawn(|| {
                    compiled
                        .get_or_compile("same", || {
                            compiles.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                            std::thread::sleep(std::time::Duration::from_millis(50));
                            Ok(module(7))
                        })
                        .unwrap();
                });
            }
        });
        assert_eq!(compiles.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(compiled.flights.lock().unwrap().is_empty());
    }

    /// A module that does not compile is not cached, so the next run tries again.
    #[test]
    fn a_failed_compile_is_not_remembered() {
        let compiled = Compiled::default();
        let failed = compiled.get_or_compile("bad", || Err(RunError::Instantiate("nope".into())));
        assert!(failed.is_err());
        assert!(compiled.cached("bad").is_none());
        assert!(compiled.get_or_compile("bad", || Ok(module(1))).is_ok());
    }
}
