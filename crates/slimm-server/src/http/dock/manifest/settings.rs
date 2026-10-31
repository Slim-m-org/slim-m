// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The manifest's `settings`: values an admin sets for a module, checked here
//! so a stored definition is always internally consistent.

use super::network::is_host_entry;
use super::{ManifestError, bounded, malformed};
use crate::store::{ModuleSettingDef, SettingChoice, SettingKind};

const MAX_SETTINGS: usize = 32;
const MAX_KEY: usize = 64;
const MAX_LABEL: usize = 40;
const MAX_HELP: usize = 140;
const MAX_CHOICES: usize = 16;
const MAX_CHOICE_VALUE: usize = 64;

fn valid_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= MAX_KEY
        && key
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

pub(super) fn validate_settings(
    raw: Vec<ModuleSettingDef>,
) -> Result<Vec<ModuleSettingDef>, ManifestError> {
    if raw.len() > MAX_SETTINGS {
        return Err(malformed("manifest declares too many settings"));
    }
    let mut settings: Vec<ModuleSettingDef> = Vec::with_capacity(raw.len());
    for def in raw {
        let checked = validate_one(def)?;
        if settings.iter().any(|s| s.key == checked.key) {
            return Err(malformed("duplicate setting key in manifest"));
        }
        settings.push(checked);
    }
    Ok(settings)
}

fn validate_one(mut def: ModuleSettingDef) -> Result<ModuleSettingDef, ManifestError> {
    if !valid_key(&def.key) {
        return Err(malformed(
            "setting key must be lowercase letters, digits and underscores",
        ));
    }
    def.label = bounded(&def.label, MAX_LABEL, "setting.label")?;
    def.help = def
        .help
        .map(|h| bounded(&h, MAX_HELP, "setting.help"))
        .transpose()?;
    check_fields_fit_type(&def)?;
    if def.kind == SettingKind::Choice {
        validate_choices(&mut def.choices)?;
    }
    if def.kind == SettingKind::Int && def.min.zip(def.max).is_some_and(|(lo, hi)| lo > hi) {
        return Err(malformed("setting min is above its max"));
    }
    if let Some(default) = &def.default {
        def.check_value(default)
            .map_err(|why| malformed(&format!("setting default {why}")))?;
    }
    normalize_hosts(&mut def.hosts)?;
    Ok(def)
}

fn normalize_hosts(hosts: &mut Vec<String>) -> Result<(), ManifestError> {
    for host in hosts.iter_mut() {
        host.make_ascii_lowercase();
        if !is_host_entry(host) {
            return Err(malformed("setting hosts must be a host name or host:port"));
        }
    }
    hosts.dedup();
    Ok(())
}

/// A secret may only be bound to hosts the module declares under `network.hosts`.
pub(super) fn check_hosts_declared(
    settings: &[ModuleSettingDef],
    network_hosts: &[String],
) -> Result<(), ManifestError> {
    let stray = settings
        .iter()
        .flat_map(|s| &s.hosts)
        .any(|host| !network_hosts.contains(host));
    if stray {
        return Err(malformed(
            "a secret setting names a host that is not in network.hosts",
        ));
    }
    Ok(())
}

fn check_fields_fit_type(def: &ModuleSettingDef) -> Result<(), ManifestError> {
    let ranged = def.min.is_some() || def.max.is_some();
    if ranged && def.kind != SettingKind::Int {
        return Err(malformed("only an int setting has min or max"));
    }
    if !def.choices.is_empty() && def.kind != SettingKind::Choice {
        return Err(malformed("only a choice setting has choices"));
    }
    if def.kind == SettingKind::Choice && def.choices.is_empty() {
        return Err(malformed("a choice setting needs choices"));
    }
    if def.kind == SettingKind::Secret && def.default.is_some() {
        return Err(malformed("a secret setting cannot have a default"));
    }
    if def.kind != SettingKind::Secret && !def.hosts.is_empty() {
        return Err(malformed("only a secret setting has hosts"));
    }
    Ok(())
}

fn validate_choices(choices: &mut [SettingChoice]) -> Result<(), ManifestError> {
    if choices.len() > MAX_CHOICES {
        return Err(malformed("a choice setting has too many choices"));
    }
    for i in 0..choices.len() {
        let value = bounded(&choices[i].value, MAX_CHOICE_VALUE, "choice.value")?;
        let label = bounded(&choices[i].label, MAX_LABEL, "choice.label")?;
        if choices[..i].iter().any(|c| c.value == value) {
            return Err(malformed("duplicate choice value"));
        }
        choices[i] = SettingChoice { value, label };
    }
    Ok(())
}
