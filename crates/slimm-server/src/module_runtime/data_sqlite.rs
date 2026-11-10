// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The durable [`DataBackend`]: one small SQLite file per module at
//! `<modules_dir>/<module id>.db`, opened with a page cap from the module's
//! `max_mb`, WAL, a short busy timeout and a single connection.
//!
//! `host_call` is a synchronous wasm import on a blocking thread, so the trait
//! methods `block_on` the async pool, as `http::module_host::SqliteKv` does.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use serde_json::{Map, Value};
use sqlx::sqlite::{SqliteConnectOptions, SqliteJournalMode, SqlitePoolOptions, SqliteRow};
use sqlx::{ConnectOptions, Connection, Row, SqlitePool};
use tokio::runtime::Handle;

use super::data::{DataBackend, DataError, Outcome};
use super::data_migrate::{newly_unique, plan};
use super::data_schema::{ColumnType, DataSchema};
use super::data_sql::{Bind, Shape, Statement};

const BUSY_TIMEOUT: Duration = Duration::from_secs(2);
const PAGE_BYTES: u64 = 4096;
const META_SCHEMA: &str = "schema";

/// Whether `id` is safe to use as a file name: the module-id charset, nothing else.
pub fn valid_file_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
}

/// SQLite instructions between checks of the running statement's deadline.
const PROGRESS_OPS: i32 = 1000;

/// The deadline of the statement a connection is running, read by its progress handler.
struct Interrupt {
    base: Instant,
    until_ms: AtomicU64,
}

impl Interrupt {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            base: Instant::now(),
            until_ms: AtomicU64::new(u64::MAX),
        })
    }

    fn set(&self, budget: Duration) {
        let until = self.base.elapsed().saturating_add(budget).as_millis();
        self.until_ms
            .store(u64::try_from(until).unwrap_or(u64::MAX), Ordering::Relaxed);
    }

    fn clear(&self) {
        self.until_ms.store(u64::MAX, Ordering::Relaxed);
    }

    fn within_budget(&self) -> bool {
        let now = u64::try_from(self.base.elapsed().as_millis()).unwrap_or(u64::MAX);
        now < self.until_ms.load(Ordering::Relaxed)
    }
}

struct Opened {
    pool: SqlitePool,
    schema: DataSchema,
    interrupt: Arc<Interrupt>,
    /// One statement at a time, because they share the single connection and its one deadline.
    statement_turn: Mutex<()>,
}

pub struct SqliteData {
    dir: PathBuf,
    handle: Handle,
    open: Mutex<HashMap<String, Arc<Opened>>>,
    /// Held while a module's file is opened, migrated or deleted, so none of them sees another half done.
    file_locks: Mutex<HashMap<String, Arc<tokio::sync::Mutex<()>>>>,
}

impl SqliteData {
    pub fn new(dir: PathBuf, handle: Handle) -> Self {
        Self {
            dir,
            handle,
            open: Mutex::new(HashMap::new()),
            file_locks: Mutex::new(HashMap::new()),
        }
    }

    fn file_lock(&self, module_id: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut locks = self
            .file_locks
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        Arc::clone(locks.entry(module_id.to_owned()).or_default())
    }

    fn cached(&self, module_id: &str) -> Option<Arc<Opened>> {
        let open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
        open.get(module_id).cloned()
    }

    async fn close_cached(&self, module_id: &str) {
        let stale = {
            let mut open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
            open.remove(module_id)
        };
        if let Some(stale) = stale {
            stale.pool.close().await;
        }
    }

    fn path_for(&self, module_id: &str) -> Result<PathBuf, String> {
        if !valid_file_id(module_id) {
            return Err("invalid module id".to_owned());
        }
        Ok(self.dir.join(format!("{module_id}.db")))
    }

    /// Creates missing tables, columns and indexes so the module's file matches `schema`.
    pub async fn apply_schema(&self, module_id: &str, schema: &DataSchema) -> Result<(), String> {
        let path = self.path_for(module_id)?;
        let lock = self.file_lock(module_id);
        let _migrating = lock.lock().await;
        let old = stored_schema(&path).await?;
        if old.as_ref() == Some(schema) {
            return Ok(());
        }
        let ddl = plan(old.as_ref(), schema)?;
        create_file_private(&self.dir, &path).map_err(|_| "could not create the data file")?;
        self.close_cached(module_id).await;
        run_ddl(&path, &ddl, schema).await.map_err(|err| {
            tracing::warn!(%err, module = module_id, "data schema migration failed");
            "could not migrate the module's data".to_owned()
        })
    }

    /// Whether `schema` could be applied, without touching the file.
    pub async fn check_schema(&self, module_id: &str, schema: &DataSchema) -> Result<(), String> {
        let path = self.path_for(module_id)?;
        let old = stored_schema(&path).await?;
        plan(old.as_ref(), schema)?;
        match old {
            Some(old) => refuse_duplicates(&path, &newly_unique(&old, schema)).await,
            None => Ok(()),
        }
    }

    /// The ids of every module that has a data file, installed or not.
    pub fn stored_module_ids(&self) -> Vec<String> {
        let Ok(entries) = std::fs::read_dir(&self.dir) else {
            return Vec::new();
        };
        entries
            .flatten()
            .filter_map(|e| e.file_name().into_string().ok())
            .filter_map(|name| name.strip_suffix(".db").map(str::to_owned))
            .filter(|id| valid_file_id(id))
            .collect()
    }

    /// Removes the module's file and its journal files, and whether any existed; a missing file is fine.
    pub async fn delete_data(&self, module_id: &str) -> Result<bool, String> {
        let path = self.path_for(module_id)?;
        let lock = self.file_lock(module_id);
        let _deleting = lock.lock().await;
        self.close_cached(module_id).await;
        let mut removed = false;
        for suffix in ["", "-wal", "-shm"] {
            let mut name = path.clone().into_os_string();
            name.push(suffix);
            match tokio::fs::remove_file(PathBuf::from(name)).await {
                Ok(()) => removed = true,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(_) => return Err("could not delete the module's data".to_owned()),
            }
        }
        Ok(removed)
    }

    /// The module's open pool, opening it on first use. The open waits out a migration or delete
    /// of the same file, so what it caches is the schema the file holds once they are done.
    fn opened(&self, module_id: &str, path: &Path) -> Result<Arc<Opened>, DataError> {
        if let Some(opened) = self.cached(module_id) {
            return Ok(opened);
        }
        let lock = self.file_lock(module_id);
        self.handle.block_on(async {
            let _settled = lock.lock().await;
            if let Some(opened) = self.cached(module_id) {
                return Ok(opened);
            }
            let fresh = Arc::new(open_existing(path).await?.ok_or(DataError::NoSchema)?);
            let mut open = self.open.lock().unwrap_or_else(PoisonError::into_inner);
            open.insert(module_id.to_owned(), Arc::clone(&fresh));
            Ok(fresh)
        })
    }

    fn with_opened<T>(
        &self,
        module_id: &str,
        run: impl FnOnce(&Opened) -> Result<T, DataError>,
    ) -> Result<T, DataError> {
        let path = self.path_for(module_id).map_err(|_| DataError::NoSchema)?;
        let opened = self.opened(module_id, &path)?;
        run(&opened)
    }
}

impl DataBackend for SqliteData {
    fn schema(&self, module_id: &str) -> Result<DataSchema, DataError> {
        self.with_opened(module_id, |o| Ok(o.schema.clone()))
    }

    fn execute(
        &self,
        module_id: &str,
        statement: &Statement,
        budget: Duration,
    ) -> Result<Outcome, DataError> {
        self.with_opened(module_id, |o| {
            let _turn = o
                .statement_turn
                .lock()
                .unwrap_or_else(PoisonError::into_inner);
            o.interrupt.set(budget);
            let outcome = self.handle.block_on(run(&o.pool, statement));
            o.interrupt.clear();
            outcome
        })
    }
}

#[cfg(unix)]
fn create_file_private(dir: &Path, path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
    {
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
        other => other.map(|_| ()),
    }
}

#[cfg(not(unix))]
fn create_file_private(dir: &Path, path: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(dir)?;
    std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map(|_| ())
}

fn options(path: &Path) -> SqliteConnectOptions {
    SqliteConnectOptions::new()
        .filename(path)
        .create_if_missing(false)
        .journal_mode(SqliteJournalMode::Wal)
        .busy_timeout(BUSY_TIMEOUT)
}

fn unreadable<E>(_: E) -> String {
    "could not read the module's data".to_owned()
}

/// The schema a file was last migrated to; `None` when it has no file or no schema yet.
async fn stored_schema(path: &Path) -> Result<Option<DataSchema>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let mut conn = options(path).connect().await.map_err(unreadable)?;
    let row = sqlx::query("SELECT value FROM _slim_meta WHERE key = ?")
        .bind(META_SCHEMA)
        .fetch_optional(&mut conn)
        .await;
    let _ = conn.close().await;
    // A file without the meta table has simply not been migrated yet.
    let Ok(Some(row)) = row else {
        return Ok(None);
    };
    let text: String = row.try_get(0).map_err(unreadable)?;
    serde_json::from_str(&text).map(Some).map_err(unreadable)
}

async fn open_existing(path: &Path) -> Result<Option<Opened>, DataError> {
    let Some(schema) = stored_schema(path)
        .await
        .map_err(|_| DataError::Unavailable)?
    else {
        return Ok(None);
    };
    let pages = u64::from(schema.max_mb) * 1024 * 1024 / PAGE_BYTES;
    let interrupt = Interrupt::new();
    let watched = Arc::clone(&interrupt);
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .after_connect(move |conn, _| {
            let watched = Arc::clone(&watched);
            Box::pin(async move {
                let mut handle = conn.lock_handle().await?;
                handle.set_progress_handler(PROGRESS_OPS, move || watched.within_budget());
                Ok(())
            })
        })
        .acquire_timeout(BUSY_TIMEOUT * 2)
        .connect_with(options(path).pragma("max_page_count", pages.to_string()))
        .await
        .map_err(|_| DataError::Unavailable)?;
    Ok(Some(Opened {
        pool,
        schema,
        interrupt,
        statement_turn: Mutex::new(()),
    }))
}

async fn run_ddl(path: &Path, ddl: &[String], schema: &DataSchema) -> Result<(), sqlx::Error> {
    let mut conn = options(path).connect().await?;
    let mut tx = conn.begin().await?;
    sqlx::query(
        "CREATE TABLE IF NOT EXISTS _slim_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
    )
    .execute(&mut *tx)
    .await?;
    for statement in ddl {
        sqlx::query(statement).execute(&mut *tx).await?;
    }
    let json = serde_json::to_string(schema).unwrap_or_default();
    sqlx::query("INSERT INTO _slim_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        .bind(META_SCHEMA)
        .bind(json)
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    conn.close().await
}

/// Refuses a new unique index over a column whose rows already repeat a value; NULLs may repeat.
async fn refuse_duplicates(path: &Path, columns: &[(String, String)]) -> Result<(), String> {
    if columns.is_empty() {
        return Ok(());
    }
    let mut conn = options(path).connect().await.map_err(unreadable)?;
    let mut result = Ok(());
    for (table, column) in columns {
        let sql = format!(
            "SELECT 1 FROM \"{table}\" WHERE \"{column}\" IS NOT NULL GROUP BY \"{column}\" HAVING COUNT(*) > 1 LIMIT 1"
        );
        match sqlx::query(&sql).fetch_optional(&mut conn).await {
            Ok(None) => {}
            Ok(Some(_)) => {
                result = Err(format!(
                    "column {table}.{column} already holds repeated values, so it cannot become unique"
                ));
                break;
            }
            Err(_) => {
                result = Err(unreadable(()));
                break;
            }
        }
    }
    let _ = conn.close().await;
    result
}

fn classify(err: &sqlx::Error) -> DataError {
    let Some(db) = err.as_database_error() else {
        return DataError::Unavailable;
    };
    match db.code().as_deref() {
        Some("13") => DataError::Full,
        Some("9") => DataError::TooSlow,
        Some("2067" | "1555") => DataError::Conflict,
        _ if db.message().contains("database or disk is full") => DataError::Full,
        _ => DataError::Unavailable,
    }
}

async fn run(pool: &SqlitePool, statement: &Statement) -> Result<Outcome, DataError> {
    let mut query = sqlx::query(&statement.sql);
    for bind in &statement.binds {
        query = match bind {
            Bind::Int(n) => query.bind(*n),
            Bind::Real(f) => query.bind(*f),
            Bind::Text(s) => query.bind(s.as_str()),
            Bind::Null => query.bind(None::<i64>),
        };
    }
    let map = |e: sqlx::Error| classify(&e);
    match &statement.shape {
        Shape::Rows(columns) => {
            let rows = query.fetch_all(pool).await.map_err(map)?;
            let rows = rows
                .iter()
                .map(|row| decode_row(row, columns))
                .collect::<Result<_, _>>()?;
            Ok(Outcome {
                rows,
                ..Outcome::default()
            })
        }
        Shape::Returning(columns) => {
            let rows = query.fetch_all(pool).await.map_err(map)?;
            let rows: Vec<_> = rows
                .iter()
                .map(|row| decode_row(row, columns))
                .collect::<Result<_, _>>()?;
            Ok(Outcome {
                changed: rows.len() as u64,
                rows,
                scalar: None,
            })
        }
        Shape::Insert => {
            let done = query.execute(pool).await.map_err(map)?;
            let mut row = Map::new();
            row.insert("_id".to_owned(), done.last_insert_rowid().into());
            Ok(Outcome {
                rows: vec![row],
                changed: done.rows_affected(),
                scalar: None,
            })
        }
        Shape::Changed => {
            let done = query.execute(pool).await.map_err(map)?;
            Ok(Outcome {
                changed: done.rows_affected(),
                ..Outcome::default()
            })
        }
        Shape::Scalar(ty) => {
            let row = query.fetch_one(pool).await.map_err(map)?;
            let value = decode(&row, 0, *ty)?;
            Ok(Outcome {
                scalar: Some(value),
                ..Outcome::default()
            })
        }
    }
}

fn decode_row(
    row: &SqliteRow,
    columns: &[(String, ColumnType)],
) -> Result<Map<String, Value>, DataError> {
    let mut out = Map::new();
    for (i, (name, ty)) in columns.iter().enumerate() {
        out.insert(name.clone(), decode(row, i, *ty)?);
    }
    Ok(out)
}

fn decode(row: &SqliteRow, index: usize, ty: ColumnType) -> Result<Value, DataError> {
    let bad = |_| DataError::Unavailable;
    Ok(match ty {
        ColumnType::Int => row.try_get::<Option<i64>, _>(index).map_err(bad)?.into(),
        ColumnType::Real => match row.try_get::<Option<f64>, _>(index).map_err(bad)? {
            None => Value::Null,
            Some(x) => {
                Value::Number(serde_json::Number::from_f64(x).ok_or(DataError::Unavailable)?)
            }
        },
        ColumnType::Text => row.try_get::<Option<String>, _>(index).map_err(bad)?.into(),
        ColumnType::Bool => row
            .try_get::<Option<i64>, _>(index)
            .map_err(bad)?
            .map_or(Value::Null, |n| Value::Bool(n != 0)),
    })
}
