// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A module's `data.store` surface over a real file, driven the way a run
//! drives it: one JSON request in, one JSON reply out.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};
use slimm_server::module_runtime::{
    CapabilitySurface, InMemoryKv, SqliteData, validate_data_schema,
};
use tokio::runtime::Handle;

pub struct Rig {
    pub dir: PathBuf,
    pub id: String,
    approved: Vec<String>,
    surface: CapabilitySurface,
}

pub fn xp_schema() -> Value {
    json!({ "max_mb": 8, "tables": [{ "name": "xp", "columns": [
        { "name": "user_id", "type": "text", "unique": true },
        { "name": "points", "type": "int", "index": true },
        { "name": "ratio", "type": "real" },
        { "name": "active", "type": "bool" }] }] })
}

pub fn files(dir: &Path) -> SqliteData {
    SqliteData::new(dir.to_path_buf(), Handle::current())
}

fn surface(dir: &Path, id: &str, approved: &[String]) -> CapabilitySurface {
    CapabilitySurface::enabled(approved.to_vec(), id, Arc::new(InMemoryKv::default()))
        .with_data(Arc::new(files(dir)))
}

impl Rig {
    pub async fn new(dir: &Path, id: &str, schema: Value) -> Rig {
        let parsed = validate_data_schema(&schema).expect("a valid schema");
        files(dir).apply_schema(id, &parsed).await.expect("apply");
        Rig::attach(dir, id, &["data.store", "kv.store"])
    }

    /// A surface over whatever file `id` already has, approved for `approved`.
    pub fn attach(dir: &Path, id: &str, approved: &[&str]) -> Rig {
        let approved: Vec<String> = approved.iter().map(ToString::to_string).collect();
        Rig {
            dir: dir.to_path_buf(),
            id: id.to_owned(),
            surface: surface(dir, id, &approved),
            approved,
        }
    }

    /// A fresh run: the per-run call budgets start over.
    pub fn renew(&mut self) {
        self.surface = surface(&self.dir, &self.id, &self.approved);
    }

    pub fn raw(&mut self, request: &Value) -> Value {
        let bytes = request.to_string().into_bytes();
        let reply = tokio::task::block_in_place(|| self.surface.dispatch(&bytes));
        serde_json::from_slice(&reply).expect("a JSON reply")
    }

    /// As [`raw`](Self::raw), with the run's wall-clock `deadline`.
    pub fn raw_before(&mut self, request: &Value, deadline: std::time::Instant) -> Value {
        let bytes = request.to_string().into_bytes();
        let reply =
            tokio::task::block_in_place(|| self.surface.dispatch_before(&bytes, Some(deadline)));
        serde_json::from_slice(&reply).expect("a JSON reply")
    }

    pub fn store(&mut self, mut request: Value) -> Value {
        request["capability"] = json!("data.store");
        self.raw(&request)
    }

    pub fn ok(&mut self, request: Value) -> Value {
        let reply = self.store(request.clone());
        assert_eq!(reply["ok"], json!(true), "{request} -> {reply}");
        reply
    }

    pub fn refused(&mut self, request: Value) -> String {
        let reply = self.store(request.clone());
        assert_eq!(reply["ok"], json!(false), "{request} -> {reply}");
        reply["error"].as_str().unwrap().to_owned()
    }
}
