// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates schema/openapi.yaml against the routes axum actually serves.
//!
//! Both sides are parsed straight out of their source text rather than
//! trusted by inspection, because a schema that only has to be updated by
//! someone remembering to do it always rots: this project has already
//! shipped with the documented surface stuck at a fraction of the real one.
//!
//! The actual scanning lives in `tests/support/openapi.rs`, shared with
//! `tests/it_infra/openapi_429_coverage.rs`'s "every charging route documents 429"
//! gate, so the router side has exactly one hand-rolled scanner between the
//! two rather than a second brace-counter that can quietly diverge from this
//! one.
//!
//! The crate-level `dead_code` allow covers the shared `support` module: an
//! integration test is its own crate, so every helper this binary does not
//! call (most of `support`'s test-database and SQL-scanning helpers) reads
//! as unused, and this one wants only the schema/router scanners.
#![allow(dead_code)]

use std::collections::BTreeSet;
use std::path::Path;

use crate::support;
use support::openapi::{Method, extract_router_routes, extract_schema_routes, normalize};

#[test]
fn openapi_matches_router() {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .expect("crates/slimm-server is two directories below the repo root");

    let router_routes = extract_router_routes(manifest_dir);
    let schema_routes = extract_schema_routes(repo_root);

    let router_keys: BTreeSet<(Method, String)> = router_routes
        .iter()
        .map(|r| (r.method, normalize(&r.path)))
        .collect();
    let schema_keys: BTreeSet<(Method, String)> = schema_routes
        .iter()
        .map(|r| (r.method, normalize(&r.path)))
        .collect();

    let mut problems = Vec::new();

    for route in &router_routes {
        let key = (route.method, normalize(&route.path));
        if !schema_keys.contains(&key) {
            problems.push(format!(
                "{} {} is served by the router ({}:{}) but is not documented in schema/openapi.yaml",
                route.method.as_str(),
                route.path,
                route.file,
                route.line
            ));
        }
    }

    for route in &schema_routes {
        let key = (route.method, normalize(&route.path));
        if !router_keys.contains(&key) {
            problems.push(format!(
                "{} {} is documented in schema/openapi.yaml:{} but is not served by any router route",
                route.method.as_str(),
                route.path,
                route.line
            ));
        }
    }

    problems.sort();
    problems.dedup();

    assert!(
        problems.is_empty(),
        "\nschema/openapi.yaml has drifted from the routes the server actually serves:\n\n{}\n",
        problems.join("\n")
    );
}
