// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Shared by every integration test binary via `mod support;` (a `mod.rs`
//! directory is never auto-discovered as its own test target, unlike a
//! sibling `main.rs`). A subdirectory binary reaches it with
//! `#[path = "../support/mod.rs"] mod support;`.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use slimm_server::config::Config;
use slimm_server::ids::{ChannelId, UserId};
use slimm_server::presence::PresenceTracker;
use slimm_server::store::Store;

/// Route and schema extraction shared by `tests/openapi_contract.rs` and
/// `tests/openapi_429_coverage.rs`.
pub mod openapi;

/// Canvas reads and removals through the product's own paths.
#[allow(dead_code)]
pub mod canvas;

/// A one-member deployment plus helpers to install and run a wasm module.
#[allow(dead_code)]
pub mod module_world;
/// Router and account helpers shared by the channel-overwrite test binaries.
pub mod overwrite_harness;

/// Filing a report under a fresh id.
#[allow(dead_code)]
pub mod reports;

/// A voice channel with two bots on its call, for the watch session tests.
#[allow(dead_code)]
pub mod watch_world;

/// Wasm fixtures for `crate::module_runtime`, shared by every test that
/// installs a module and actually invokes it.
#[allow(dead_code)]
pub mod wasm_fixtures;

/// [`slimm_server::push::message_recipients`] against a fresh, empty
/// [`PresenceTracker`] - shared by every push-recipient test that has no
/// opinion about `@here`, so a perpetually-disconnected tracker is a correct
/// no-op stand-in rather than a parameter each call site has to carry.
///
/// Allowed dead: this module is included by every test binary, and most of
/// them never touch push recipients at all.
#[allow(dead_code)]
pub async fn wake_recipients(
    store: &Store,
    channel_id: ChannelId,
    author_id: UserId,
    content: &str,
) -> anyhow::Result<Vec<UserId>> {
    slimm_server::push::message_recipients(
        store,
        channel_id,
        author_id,
        content,
        &PresenceTracker::new(),
    )
    .await
}

/// Deletes its temp SQLite database, and its `-wal`/`-shm` siblings, on drop.
///
/// Runs on a panicking test too: `Drop` still runs during unwind, which is
/// exactly the case that matters, since a failing test is the one that gets
/// re-run and accumulates.
pub struct TestDbGuard(PathBuf);

impl TestDbGuard {
    /// A fresh unique path under `prefix` in the system temp dir, paired with
    /// a guard that removes it (and its `-wal`/`-shm` siblings) on drop.
    ///
    /// The path is seeded from a pre-migrated template so the `db::connect` that
    /// follows finds every migration already applied - a fast no-op - instead of
    /// running all of them from scratch. Measured on this suite: ~58 ms/connect
    /// migrating vs ~7 ms copy-then-connect, ~50 ms saved across ~1000 test DBs.
    /// If the template cannot be built the copy is skipped and `connect` migrates
    /// from scratch exactly as before, so this can only ever lose the speedup,
    /// never correctness.
    #[allow(dead_code)]
    pub fn new(prefix: &str) -> (String, Self) {
        let path = std::env::temp_dir().join(format!("{prefix}-{}.db", uuid::Uuid::now_v7()));
        if let Some(template) = template_db() {
            let _ = std::fs::copy(&template, &path);
        }
        let display = path.to_string_lossy().into_owned();
        (display, Self(path))
    }

    /// Like [`new`](Self::new) but seeds nothing: the path names a file that
    /// does not exist yet. For the migration-state tests that open the path
    /// themselves and run migrations to a specific version (a backfill or a
    /// rebuild under test) - a pre-migrated template would defeat exactly what
    /// they exercise.
    #[allow(dead_code)]
    pub fn empty(prefix: &str) -> (String, Self) {
        let path = std::env::temp_dir().join(format!("{prefix}-{}.db", uuid::Uuid::now_v7()));
        let display = path.to_string_lossy().into_owned();
        (display, Self(path))
    }
}

/// A migrated SQLite database file all test DBs are copied from, so migrations
/// run once per test session rather than once per test. `None` if it could not
/// be built, which drops callers back to migrating from scratch.
///
/// Keyed by a hash of the migration files so a changed migration set builds a
/// fresh template rather than reusing a stale one. Shared across processes on
/// disk because `cargo nextest` runs each test in its own process: the first to
/// need it builds it, the rest copy it.
#[allow(dead_code)]
fn template_db() -> Option<PathBuf> {
    static TEMPLATE: OnceLock<Option<PathBuf>> = OnceLock::new();
    TEMPLATE.get_or_init(build_or_find_template).clone()
}

#[allow(dead_code)]
fn build_or_find_template() -> Option<PathBuf> {
    let final_path = std::env::temp_dir().join(format!("slimm-test-tpl-{}.db", migrations_hash()));
    if is_nonempty(&final_path) {
        return Some(final_path);
    }
    // Build to a private path, then publish by an atomic rename; a concurrent copier of the old file keeps reading it through its open handle, so builders racing to publish an identical template is harmless.
    let building = std::env::temp_dir().join(format!(
        "slimm-test-tpl-{}.{}.building",
        migrations_hash(),
        uuid::Uuid::now_v7()
    ));
    if migrate_fresh(&building).is_err() {
        remove(&building);
        return None;
    }
    let _ = std::fs::rename(&building, &final_path);
    remove(&building);
    is_nonempty(&final_path).then_some(final_path)
}

/// Runs `db::connect` (which migrates) against `dest`, on a dedicated thread
/// with its own runtime: [`TestDbGuard::new`] is called from inside the test's
/// tokio runtime, and a nested runtime would panic.
#[allow(dead_code)]
fn migrate_fresh(dest: &Path) -> anyhow::Result<()> {
    let database_path = dest.to_string_lossy().into_owned();
    std::thread::spawn(move || -> anyhow::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        runtime.block_on(async move {
            let config = Config {
                port: 0,
                database_path,
                hash_concurrency: 2,
                ..Config::default()
            };
            let pool = slimm_server::db::connect(&config).await?;
            // Fold the WAL into the main file so a plain copy of it is complete.
            let _ = sqlx::query("PRAGMA wal_checkpoint(TRUNCATE)")
                .execute(&pool)
                .await;
            pool.close().await;
            Ok(())
        })
    })
    .join()
    .map_err(|_| anyhow::anyhow!("template build thread panicked"))?
}

/// A stable hash of the migration set (name and contents), so the template is
/// rebuilt whenever a migration is added or edited rather than going stale.
#[allow(dead_code)]
fn migrations_hash() -> u64 {
    use std::hash::{Hash, Hasher};
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("migrations");
    let mut entries: Vec<PathBuf> = std::fs::read_dir(&dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|e| e == "sql"))
        .collect();
    entries.sort();
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    for path in entries {
        path.file_name().hash(&mut hasher);
        if let Ok(bytes) = std::fs::read(&path) {
            bytes.hash(&mut hasher);
        }
    }
    hasher.finish()
}

#[allow(dead_code)]
fn is_nonempty(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|m| m.len() > 0)
        .unwrap_or(false)
}

impl Drop for TestDbGuard {
    fn drop(&mut self) {
        remove(&self.0);
        remove(&sibling(&self.0, "-wal"));
        remove(&sibling(&self.0, "-shm"));
    }
}

fn sibling(path: &Path, suffix: &str) -> PathBuf {
    let mut name = path.as_os_str().to_owned();
    name.push(suffix);
    PathBuf::from(name)
}

fn remove(path: &Path) {
    let _ = std::fs::remove_file(path);
}

/// Deletes a temp *directory tree* on drop, for the fixtures that build a
/// media root or an import pack rather than a database.
///
/// Allowed dead: this module is included by every test binary, and most of
/// them have no directory fixture to guard.
#[allow(dead_code)]
pub struct TestDirGuard(PathBuf);

#[allow(dead_code)]
impl TestDirGuard {
    pub fn new(prefix: &str) -> (PathBuf, Self) {
        let path = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::now_v7()));
        (path.clone(), Self(path))
    }
}

impl Drop for TestDirGuard {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Blanks `//` and `/* */` comments and `"..."`/raw-string (`r"..."`,
/// `r#"..."#`, ...) literals to spaces, keeping every byte's position, so
/// [function_body]'s brace count only ever sees real code.
///
/// A stray unmatched `}` inside an ordinary `//` comment - "think of this
/// like a code block }" is enough - closed a naive brace-depth scan the
/// moment it appeared, hiding a real second `.fetch_all(`/`&self.pool`
/// call placed after it in the actual function; reproduced directly,
/// independently, against both `canvas_index.rs`'s and
/// `thread_reply_count.rs`'s own former private copies of this logic
/// before this shared one replaced them. Raw strings need their own
/// handling because this crate's own SQL literals (`r#"SELECT ..."#`) are
/// exactly that shape.
#[allow(dead_code)]
pub fn code_only(source: &str) -> String {
    let bytes = source.as_bytes();
    let mut out = vec![b' '; bytes.len()];
    let mut i = 0usize;
    while i < bytes.len() {
        if bytes[i] == b'r' {
            let mut hashes = 0usize;
            let mut j = i + 1;
            while j < bytes.len() && bytes[j] == b'#' {
                hashes += 1;
                j += 1;
            }
            if j < bytes.len() && bytes[j] == b'"' {
                let close: Vec<u8> = std::iter::once(b'"')
                    .chain(std::iter::repeat_n(b'#', hashes))
                    .collect();
                let mut k = j + 1;
                while k < bytes.len() && bytes[k..].get(..close.len()) != Some(close.as_slice()) {
                    k += 1;
                }
                let end = (k + close.len()).min(bytes.len());
                for idx in i..end {
                    if bytes[idx] == b'\n' {
                        out[idx] = b'\n';
                    }
                }
                i = end.max(i + 1);
                continue;
            }
        }
        if bytes[i] == b'"' {
            let mut k = i + 1;
            while k < bytes.len() && bytes[k] != b'"' {
                k += if bytes[k] == b'\\' { 2 } else { 1 };
            }
            let end = (k + 1).min(bytes.len());
            for idx in i..end {
                if bytes[idx] == b'\n' {
                    out[idx] = b'\n';
                }
            }
            i = end;
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'/') {
            while i < bytes.len() && bytes[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if bytes[i] == b'/' && bytes.get(i + 1) == Some(&b'*') {
            let mut k = i + 2;
            while k < bytes.len() && bytes.get(k..k + 2) != Some(b"*/") {
                k += 1;
            }
            let end = (k + 2).min(bytes.len());
            for idx in i..end {
                if bytes[idx] == b'\n' {
                    out[idx] = b'\n';
                }
            }
            i = end;
            continue;
        }
        out[i] = bytes[i];
        i += 1;
    }
    String::from_utf8(out)
        .expect("only ever ASCII space/newline or original bytes, so always valid utf-8")
}

/// A function's body, from its signature's `marker` to the matching closing
/// brace, by depth counting over [code_only] rather than the raw source, so
/// a comment's or a string's own brace-shaped text cannot end the scan
/// early. Panics naming `marker` (function no longer found) or `source`
/// (unterminated) rather than returning a `Result`, since every caller is a
/// test whose only recovery from either is to fail loudly anyway.
#[allow(dead_code)]
pub fn function_body(source: &str, marker: &str) -> String {
    let scrubbed = code_only(source);
    let start = scrubbed
        .find(marker)
        .unwrap_or_else(|| panic!("{marker} no longer appears in the source"));
    let mut depth = 0i32;
    let mut opened = false;
    for (i, ch) in scrubbed[start..].char_indices() {
        match ch {
            '{' => {
                depth += 1;
                opened = true;
            }
            '}' => {
                depth -= 1;
                if opened && depth == 0 {
                    return scrubbed[start..start + i + 1].to_owned();
                }
            }
            _ => {}
        }
    }
    panic!("{marker}'s body has no matching closing brace")
}

#[allow(dead_code)]
/// The SQL of the first `sqlx::query*!` call whose literal contains [anchor],
/// plain or raw.
///
/// Anchored to a real macro call rather than to the nearest quote, because the
/// nearest quote can belong to a comment. A comment quoting an older version of
/// the query is extracted and validated in place of the code by a bare search,
/// so the query itself can regress to a scan while this passes - the
/// source-reading-gate trap `support::code_only` exists for, demonstrated
/// against this very file before it was written this way. Asserting the anchor
/// is unique does not close it: once the real query stops matching, the stale
/// comment is the only occurrence left.
///
/// `code_only` blanks comments and strings in place and keeps every byte
/// offset, so a call site found in its output is a call site in real code, and
/// the literal is then read back out of the original source at that offset.
pub fn query_literal_containing(source: &str, anchor: &str) -> String {
    let code = code_only(source);
    let mut from = 0usize;
    while let Some(rel) = code[from..].find("query") {
        let at = from + rel;
        from = at + 1;
        let Some(paren) = code[at..].find('(') else {
            continue;
        };
        let name = &code[at..at + paren];
        let macro_call = name.ends_with('!')
            && name[..name.len() - 1]
                .chars()
                .all(|c| c.is_alphanumeric() || c == '_');
        if !macro_call {
            continue;
        }
        if let Some(sql) = literal_at(source, at + paren + 1)
            && sql.contains(anchor)
        {
            return sql;
        }
    }
    panic!("no sqlx query literal contains {anchor:?}; has the query itself changed?")
}

/// The string literal starting at the next non-whitespace byte, `r#"..."#`
/// included, or `None` when what follows is not one.
fn literal_at(source: &str, from: usize) -> Option<String> {
    let bytes = source.as_bytes();
    let mut i = from;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }
    if bytes.get(i) == Some(&b'r') {
        let mut hashes = 0usize;
        let mut j = i + 1;
        while bytes.get(j) == Some(&b'#') {
            hashes += 1;
            j += 1;
        }
        if bytes.get(j) != Some(&b'"') {
            return None;
        }
        let close: String = std::iter::once('"')
            .chain(std::iter::repeat_n('#', hashes))
            .collect();
        let start = j + 1;
        let end = source[start..].find(&close)? + start;
        return Some(source[start..end].to_owned());
    }
    if bytes.get(i) == Some(&b'"') {
        let start = i + 1;
        let end = source[start..].find('"')? + start;
        return Some(source[start..end].to_owned());
    }
    None
}
