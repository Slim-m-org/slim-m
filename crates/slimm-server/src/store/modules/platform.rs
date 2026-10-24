// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The module-platform shapes recorded at install (decision 0091): setting
//! definitions and slots. The manifest validates them; this module only stores
//! them and judges a value against a definition.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Longest text a `string` or `secret` setting holds.
pub const MAX_SETTING_TEXT: usize = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum SettingKind {
    #[serde(rename = "bool")]
    Bool,
    #[serde(rename = "int")]
    Int,
    #[serde(rename = "string")]
    String,
    #[serde(rename = "choice")]
    Choice,
    #[serde(rename = "secret")]
    Secret,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingChoice {
    pub value: String,
    pub label: String,
}

/// One declared setting. Fields that do not apply to `kind` stay empty.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ModuleSettingDef {
    pub key: String,
    #[serde(rename = "type")]
    pub kind: SettingKind,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub help: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub min: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max: Option<i64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub choices: Vec<SettingChoice>,
}

/// What a manifest declares under decision 0091, as install records it.
#[derive(Debug, Clone, Default)]
pub struct ModulePlatform {
    pub addon_api: u32,
    pub subscriptions: Vec<String>,
    pub data_schema: serde_json::Value,
    pub settings_schema: Vec<ModuleSettingDef>,
    pub slots: Vec<ModuleSlot>,
}

/// A place in the client a module may fill (`profile.section`, `member.badge`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModuleSlot {
    pub kind: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
}

impl ModuleSettingDef {
    /// Whether `value` is a legal value for this setting.
    pub fn check_value(&self, value: &Value) -> Result<(), &'static str> {
        match (self.kind, value) {
            (SettingKind::Bool, Value::Bool(_)) => Ok(()),
            (SettingKind::Int, Value::Number(n)) => {
                let n = n.as_i64().ok_or("must be a whole number")?;
                if self.min.is_some_and(|m| n < m) || self.max.is_some_and(|m| n > m) {
                    return Err("is out of range");
                }
                Ok(())
            }
            (SettingKind::String | SettingKind::Secret, Value::String(s)) => {
                if s.chars().count() > MAX_SETTING_TEXT {
                    return Err("is too long");
                }
                Ok(())
            }
            (SettingKind::Choice, Value::String(s)) => {
                if self.choices.iter().any(|c| &c.value == s) {
                    Ok(())
                } else {
                    Err("is not one of the choices")
                }
            }
            _ => Err("has the wrong type"),
        }
    }
}

/// Records what the manifest declared under decision 0091 on the module's row.
pub(super) async fn write_platform(
    tx: &mut sqlx::Transaction<'_, sqlx::Sqlite>,
    id: &str,
    platform: &ModulePlatform,
) -> anyhow::Result<()> {
    let addon_api = i64::from(platform.addon_api);
    let subscriptions = serde_json::to_string(&platform.subscriptions)?;
    let data_schema = serde_json::to_string(&platform.data_schema)?;
    let settings_schema = serde_json::to_string(&platform.settings_schema)?;
    let slots = serde_json::to_string(&platform.slots)?;
    sqlx::query!(
        "UPDATE installed_modules
         SET addon_api = ?, subscriptions = ?, data_schema = ?, settings_schema = ?, slots = ?
         WHERE id = ?",
        addon_api,
        subscriptions,
        data_schema,
        settings_schema,
        slots,
        id
    )
    .execute(&mut **tx)
    .await?;
    Ok(())
}
