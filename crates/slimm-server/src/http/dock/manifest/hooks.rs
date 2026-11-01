// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's `interceptors` and `permission_hooks` (decision 0100): where
//! a module asks to stand in front of a message or a permission check, and what
//! it reads there. Checked here so a stored hook is always one the host knows.

use serde::Deserialize;

use super::{ManifestError, malformed};
use crate::store::{HookDecl, HookKind};

const MAX_INTERCEPTORS: usize = 4;
const MAX_PERMISSION_HOOKS: usize = 4;
/// The add-on API level that introduced hooks.
const HOOKS_API: i64 = 3;

pub(in crate::http) const INTERCEPTOR_CAPABILITY: &str = "interceptors";
pub(in crate::http) const PERMISSION_CAPABILITY: &str = "permission.hook";

/// Where a message interceptor may stand.
pub(in crate::http) const MESSAGE_HOOKS: [&str; 2] = ["message.pre_send", "message.pre_edit"];
/// The order interceptors run in.
pub(in crate::http) const PHASES: [&str; 3] = ["reject", "annotate", "rewrite"];
/// What an interceptor may ask to be sent about a message.
pub(in crate::http) const MESSAGE_READS: [&str; 5] = [
    "content",
    "channel_id",
    "is_bot",
    "reply_to_id",
    "annotations",
];
/// The actions a permission hook may stand in front of.
pub(in crate::http) const ACTIONS: [&str; 4] = [
    "message.send",
    "attachment.upload",
    "reaction.add",
    "voice.join",
];
/// What a permission hook may ask to be sent about the member.
pub(in crate::http) const PERMISSION_READS: [&str; 1] = ["member_joined_ms"];

#[derive(Deserialize)]
/// An interceptor as the manifest wrote it.
#[serde(deny_unknown_fields)]
pub(super) struct RawInterceptor {
    hook: String,
    phase: String,
    #[serde(default)]
    reads: Vec<String>,
}

#[derive(Deserialize)]
/// A permission hook as the manifest wrote it.
#[serde(deny_unknown_fields)]
pub(super) struct RawPermissionHook {
    action: String,
    #[serde(default)]
    reads: Vec<String>,
}

fn has(capabilities: &[String], name: &str) -> bool {
    capabilities.iter().any(|c| c == name)
}

/// Checks `reads` against `allowed` and returns it without repeats.
fn checked_reads(reads: Vec<String>, allowed: &[&str]) -> Result<Vec<String>, ManifestError> {
    let mut out: Vec<String> = Vec::with_capacity(reads.len());
    for field in reads {
        if !allowed.contains(&field.as_str()) {
            return Err(malformed("a hook reads a field the host does not offer"));
        }
        if !out.contains(&field) {
            out.push(field);
        }
    }
    Ok(out)
}

pub(super) fn validate_hooks(
    interceptors: Vec<RawInterceptor>,
    permission_hooks: Vec<RawPermissionHook>,
    (capabilities, addon_api): (&[String], i64),
) -> Result<Vec<HookDecl>, ManifestError> {
    if interceptors.is_empty() && permission_hooks.is_empty() {
        return Ok(Vec::new());
    }
    if addon_api < HOOKS_API {
        return Err(malformed(
            "interceptors and permission hooks need \"addon_api\": 3",
        ));
    }
    let mut decls = validate_interceptors(interceptors, capabilities)?;
    decls.extend(validate_permission_hooks(permission_hooks, capabilities)?);
    Ok(decls)
}

fn validate_interceptors(
    raw: Vec<RawInterceptor>,
    capabilities: &[String],
) -> Result<Vec<HookDecl>, ManifestError> {
    if raw.is_empty() {
        return Ok(Vec::new());
    }
    if !has(capabilities, INTERCEPTOR_CAPABILITY) {
        return Err(malformed("interceptors need the interceptors capability"));
    }
    if raw.len() > MAX_INTERCEPTORS {
        return Err(malformed("manifest declares too many interceptors"));
    }
    let mut out: Vec<HookDecl> = Vec::with_capacity(raw.len());
    for entry in raw {
        if !MESSAGE_HOOKS.contains(&entry.hook.as_str()) {
            return Err(malformed("interceptor names an unknown hook"));
        }
        if !PHASES.contains(&entry.phase.as_str()) {
            return Err(malformed("interceptor names an unknown phase"));
        }
        if out
            .iter()
            .any(|d| d.hook == entry.hook && d.phase == entry.phase)
        {
            return Err(malformed(
                "an interceptor hook and phase are declared twice",
            ));
        }
        out.push(HookDecl {
            kind: HookKind::Interceptor,
            hook: entry.hook,
            phase: entry.phase,
            reads: checked_reads(entry.reads, &MESSAGE_READS)?,
        });
    }
    Ok(out)
}

fn validate_permission_hooks(
    raw: Vec<RawPermissionHook>,
    capabilities: &[String],
) -> Result<Vec<HookDecl>, ManifestError> {
    if raw.is_empty() {
        return Ok(Vec::new());
    }
    if !has(capabilities, PERMISSION_CAPABILITY) {
        return Err(malformed(
            "permission hooks need the permission.hook capability",
        ));
    }
    if raw.len() > MAX_PERMISSION_HOOKS {
        return Err(malformed("manifest declares too many permission hooks"));
    }
    let mut out: Vec<HookDecl> = Vec::with_capacity(raw.len());
    for entry in raw {
        if !ACTIONS.contains(&entry.action.as_str()) {
            return Err(malformed("permission hook names an unknown action"));
        }
        if out.iter().any(|d| d.hook == entry.action) {
            return Err(malformed("a permission hook action is declared twice"));
        }
        out.push(HookDecl {
            kind: HookKind::Permission,
            hook: entry.action,
            phase: String::new(),
            reads: checked_reads(entry.reads, &PERMISSION_READS)?,
        });
    }
    Ok(out)
}
