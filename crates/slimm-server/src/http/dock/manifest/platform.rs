// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's module-platform sections (decision 0091): `addon_api`,
//! `subscriptions`, `settings`, `slots` and the `data` passthrough. Each is
//! optional; a manifest using none installs exactly as before.

use serde::Deserialize;
use serde_json::Value;

use super::{ManifestError, bounded, malformed, settings};
use crate::store::{ModulePlatform, ModuleSettingDef, ModuleSlot};

/// The `addon_api` this host implements.
pub(in crate::http) const SUPPORTED_ADDON_API: i64 = 1;
const MAX_SUBSCRIPTIONS: usize = 8;
const MAX_SLOTS: usize = 4;
const MAX_SLOT_NAME: usize = 64;
const MAX_SLOT_TITLE: usize = 40;
const SLOT_KINDS: [&str; 2] = ["profile.section", "member.badge"];

/// The events a phase 1 module may subscribe to.
pub(in crate::http) const EVENTS: [&str; 6] = [
    "message.created",
    "message.deleted",
    "reaction.changed",
    "member.joined",
    "member.left",
    "voice.session.closed",
];

#[derive(Deserialize)]
pub(super) struct RawSubscription {
    event: String,
}

/// The raw sections as the manifest wrote them.
pub(super) struct RawPlatform {
    pub(super) addon_api: Option<i64>,
    pub(super) subscriptions: Vec<RawSubscription>,
    pub(super) settings: Vec<ModuleSettingDef>,
    pub(super) slots: Vec<ModuleSlot>,
    pub(super) data: Option<Value>,
}

fn has(capabilities: &[String], name: &str) -> bool {
    capabilities.iter().any(|c| c == name)
}

pub(super) fn validate_platform(
    raw: RawPlatform,
    capabilities: &[String],
) -> Result<ModulePlatform, ManifestError> {
    let addon_api = raw.addon_api.unwrap_or(0);
    if addon_api > SUPPORTED_ADDON_API {
        return Err(malformed(&format!(
            "this module needs add-on API {addon_api}, but this server supports up to {SUPPORTED_ADDON_API}; update the server"
        )));
    }
    if addon_api < 0 {
        return Err(malformed("addon_api must not be negative"));
    }
    let subscriptions = validate_subscriptions(raw.subscriptions, capabilities)?;
    let settings = settings::validate_settings(raw.settings)?;
    let slots = validate_slots(raw.slots)?;
    if raw.data.is_some() && !has(capabilities, "data.store") {
        return Err(malformed("data needs the data.store capability"));
    }
    let uses_platform = !subscriptions.is_empty()
        || !settings.is_empty()
        || !slots.is_empty()
        || raw.data.is_some();
    if uses_platform && addon_api < 1 {
        return Err(malformed(
            "subscriptions, settings, slots and data need \"addon_api\": 1",
        ));
    }
    Ok(ModulePlatform {
        addon_api: u32::try_from(addon_api).unwrap_or(0),
        subscriptions,
        data_schema: raw.data.unwrap_or(Value::Null),
        settings_schema: settings,
        slots,
    })
}

fn validate_subscriptions(
    raw: Vec<RawSubscription>,
    capabilities: &[String],
) -> Result<Vec<String>, ManifestError> {
    if raw.len() > MAX_SUBSCRIPTIONS {
        return Err(malformed("manifest declares too many subscriptions"));
    }
    if !raw.is_empty() && !has(capabilities, "events") {
        return Err(malformed("subscriptions need the events capability"));
    }
    let mut events: Vec<String> = Vec::with_capacity(raw.len());
    for entry in raw {
        if !EVENTS.contains(&entry.event.as_str()) {
            return Err(malformed("subscription names an unknown event"));
        }
        if events.contains(&entry.event) {
            return Err(malformed("a subscription is listed twice"));
        }
        events.push(entry.event);
    }
    Ok(events)
}

fn validate_slots(raw: Vec<ModuleSlot>) -> Result<Vec<ModuleSlot>, ManifestError> {
    if raw.len() > MAX_SLOTS {
        return Err(malformed("manifest declares too many slots"));
    }
    let mut slots: Vec<ModuleSlot> = Vec::with_capacity(raw.len());
    for slot in raw {
        if !SLOT_KINDS.contains(&slot.kind.as_str()) {
            return Err(malformed("slot kind is not supported"));
        }
        let name = bounded(&slot.name, MAX_SLOT_NAME, "slot.name")?;
        let title = slot
            .title
            .map(|t| bounded(&t, MAX_SLOT_TITLE, "slot.title"))
            .transpose()?;
        if slots.iter().any(|s| s.kind == slot.kind && s.name == name) {
            return Err(malformed("a slot is declared twice"));
        }
        slots.push(ModuleSlot {
            kind: slot.kind,
            name,
            title,
        });
    }
    Ok(slots)
}
