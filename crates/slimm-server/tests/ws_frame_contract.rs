// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates `ServerFrame`'s and `ClientFrame`'s `oneOf` in schema/openapi.yaml
//! against the frames the WebSocket actually serialises and accepts.
//!
//! The route surface has had `tests/openapi_contract.rs` since 2026-07-25 and
//! response bodies have `tests/response_contract/`; the socket half of the
//! protocol had neither, and drifted to documenting 15 of 21 frames without
//! anything noticing. The response contract cannot cover it (it exempts
//! `connectWebSocket` as an upgrade rather than a request), and the oasdiff
//! gate is breaking-change only, so a missing `oneOf` member is invisible to
//! both. This file is the missing third side.
//!
//! The schema calls itself the single source of record for the wire protocol
//! and this `oneOf` is the only written description of the event envelope, so
//! what an undocumented frame costs is a third-party client, or an iOS
//! Notification Service Extension, written from the schema and silently
//! dropping whatever is missing.
//!
//! Both sides are read out of their own source rather than from a list kept
//! by hand, for the reason `openapi_contract.rs` gives: a hand-kept list only
//! ever proves somebody remembered.

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .expect("repo root")
}

/// Every `type` discriminator the `ServerFrame` enum really serialises, read
/// out of its `#[serde(rename = "...")]` attributes.
///
/// Self-checked the way the route scanner is: the number of variants declared
/// must equal the number of renames found. A variant with no rename is not a
/// parse failure to shrug at, it is a live wire bug - serde would fall back to
/// the Rust variant name, so the frame would go out as `MessageCreated`
/// instead of `message.created`.
fn served_frames() -> BTreeSet<String> {
    frames_of("ServerFrame")
}

/// The `type` discriminators `ClientFrame` accepts, by the same scan.
fn accepted_frames() -> BTreeSet<String> {
    frames_of("ClientFrame")
}

fn frames_of(enum_name: &str) -> BTreeSet<String> {
    let path = repo_root().join("crates/slimm-server/src/http/ws/frames.rs");
    let source = fs::read_to_string(&path).expect("read frames.rs");

    let body = source
        .split_once(&format!("enum {enum_name} {{"))
        .unwrap_or_else(|| panic!("{enum_name} enum"))
        .1
        .split_once("\n}")
        .unwrap_or_else(|| panic!("{enum_name} enum close"))
        .0;

    let mut names = BTreeSet::new();
    let mut variants = 0usize;
    for line in body.lines() {
        if let Some(rest) = line.trim().strip_prefix("#[serde(rename = \"") {
            let name = rest.split('"').next().expect("rename value");
            assert!(
                names.insert(name.to_string()),
                "two {enum_name} variants both use `{name}`",
            );
        }
        // A variant declaration: the enum's own indent, an uppercase start.
        if let Some(rest) = line.strip_prefix("    ")
            && rest.starts_with(|c: char| c.is_ascii_uppercase())
        {
            variants += 1;
        }
    }

    assert_eq!(
        variants,
        names.len(),
        "{variants} {enum_name} variants but {} `#[serde(rename)]` attributes: \
         a variant without one uses its Rust name and breaks the wire \
         contract",
        names.len(),
    );
    assert!(
        !names.is_empty(),
        "parsed no variants of the frame enum at all"
    );
    names
}

/// Every `type` value the schema's `ServerFrame.oneOf` documents.
///
/// Resolving each `$ref` and reading its single-valued `type` enum is what
/// makes this compare like for like: a member listed in the `oneOf` whose
/// schema pins no discriminator documents no frame, and fails here rather
/// than counting as coverage.
fn documented_frames() -> BTreeSet<String> {
    documented_in("ServerFrame")
}

/// Every `type` value the schema's `ClientFrame.oneOf` documents.
fn documented_client_frames() -> BTreeSet<String> {
    documented_in("ClientFrame")
}

fn documented_in(frame_schema: &str) -> BTreeSet<String> {
    let path = repo_root().join("schema/openapi.yaml");
    let text = fs::read_to_string(&path).expect("read openapi.yaml");
    let doc: serde_yaml_ng::Value = serde_yaml_ng::from_str(&text).expect("parse openapi.yaml");

    let schemas = doc
        .get("components")
        .and_then(|c| c.get("schemas"))
        .expect("components.schemas");
    let one_of = schemas
        .get(frame_schema)
        .and_then(|f| f.get("oneOf"))
        .and_then(|o| o.as_sequence())
        .unwrap_or_else(|| panic!("{frame_schema}.oneOf"));

    let mut names = BTreeSet::new();
    for member in one_of {
        let reference = member
            .get("$ref")
            .and_then(|r| r.as_str())
            .unwrap_or_else(|| panic!("{frame_schema}.oneOf member is not a $ref: {member:?}"));
        let schema_name = reference
            .strip_prefix("#/components/schemas/")
            .unwrap_or_else(|| panic!("unresolvable {frame_schema}.oneOf $ref: {reference}"));
        let target = schemas.get(schema_name).unwrap_or_else(|| {
            panic!("{frame_schema}.oneOf names {schema_name}, which is undefined")
        });

        let discriminator = target
            .get("properties")
            .and_then(|p| p.get("type"))
            .and_then(|t| t.get("enum"))
            .and_then(|e| e.as_sequence())
            .unwrap_or_else(|| panic!("{schema_name} pins no `type` enum, so it names no frame"));
        assert_eq!(
            discriminator.len(),
            1,
            "{schema_name}'s `type` enum has {} values; one frame shape is one \
             discriminator",
            discriminator.len(),
        );
        let value = discriminator[0]
            .as_str()
            .unwrap_or_else(|| panic!("{schema_name}'s `type` enum value is not a string"));
        assert!(
            names.insert(value.to_string()),
            "two {frame_schema}.oneOf members both document `{value}`",
        );
    }
    names
}

#[test]
fn every_served_frame_is_documented() {
    let undocumented: Vec<_> = served_frames()
        .difference(&documented_frames())
        .cloned()
        .collect();
    assert!(
        undocumented.is_empty(),
        "the WebSocket sends these frames and schema/openapi.yaml's \
         ServerFrame.oneOf does not document them: {undocumented:?}\n\
         Add a schema for each and list it in the oneOf. The schema is the \
         only written description of the event envelope, so an undocumented \
         frame is one a client written from it silently drops.",
    );
}

#[test]
fn every_documented_frame_is_served() {
    let unserved: Vec<_> = documented_frames()
        .difference(&served_frames())
        .cloned()
        .collect();
    assert!(
        unserved.is_empty(),
        "schema/openapi.yaml documents these frames and the WebSocket never \
         sends them: {unserved:?}\n\
         Either the frame was removed without the schema edit, or its \
         discriminator was renamed on one side only.",
    );
}

#[test]
fn every_accepted_client_frame_is_documented() {
    let undocumented: Vec<_> = accepted_frames()
        .difference(&documented_client_frames())
        .cloned()
        .collect();
    assert!(
        undocumented.is_empty(),
        "the WebSocket accepts these client frames and schema/openapi.yaml's \
         ClientFrame.oneOf does not document them: {undocumented:?}\n\
         Add a schema for each and list it in the oneOf, or a client or bot \
         written from the schema never learns the frame exists.",
    );
}

#[test]
fn every_documented_client_frame_is_accepted() {
    let unaccepted: Vec<_> = documented_client_frames()
        .difference(&accepted_frames())
        .cloned()
        .collect();
    assert!(
        unaccepted.is_empty(),
        "schema/openapi.yaml documents these client frames and ClientFrame \
         does not accept them: {unaccepted:?}",
    );
}

/// Both directions rest on parsing actually finding something, and a scanner
/// that silently returns an empty set would make either assertion above pass
/// vacuously. This is the check that the checks are checking.
#[test]
fn both_sides_parse_to_a_real_set() {
    let served = served_frames();
    let documented = documented_frames();
    assert!(
        served.len() >= 15,
        "suspiciously few frames parsed from frames.rs: {served:?}"
    );
    assert!(
        documented.len() >= 15,
        "suspiciously few frames parsed from openapi.yaml: {documented:?}",
    );
    assert!(served.contains("message.created"));
    assert!(documented.contains("message.created"));
    assert!(
        accepted_frames().len() >= 5,
        "suspiciously few client frames"
    );
    assert!(documented_client_frames().contains("hello"));
}
