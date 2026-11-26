// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `interaction.created` frame: a member used a bot's button, menu entry, call
//! control or form. Bot connections only. `custom_id` is the entry id for the
//! menu and call kinds, and a call control names no message.

use std::collections::BTreeMap;

use serde::Serialize;

use crate::store::{Interaction, InteractionInput};

#[derive(Serialize)]
pub(super) struct InteractionClickFrame {
    interaction_id: String,
    channel_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    message_id: Option<String>,
    custom_id: String,
    kind: String,
    /// The choice made on a call control that offers options.
    #[serde(skip_serializing_if = "Option::is_none")]
    option_id: Option<String>,
    user_id: String,
    user_display_name: String,
    created_at: i64,
    /// The values chosen from a select menu.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    values: Vec<String>,
    /// A submitted form's answers by field `custom_id`.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    fields: BTreeMap<String, String>,
    /// The press the form was opened on, on a submitted form.
    #[serde(skip_serializing_if = "Option::is_none")]
    origin_interaction_id: Option<String>,
}

impl InteractionClickFrame {
    pub(super) fn new(
        interaction: &Interaction,
        clicker_display_name: &str,
        input: &InteractionInput,
    ) -> Self {
        Self {
            interaction_id: interaction.id.to_string(),
            channel_id: interaction.channel_id.to_string(),
            message_id: interaction.message_id.map(|m| m.to_string()),
            custom_id: interaction.custom_id.clone(),
            kind: interaction.kind.as_str().to_owned(),
            option_id: interaction.option_id.clone(),
            user_id: interaction.clicker_id.to_string(),
            user_display_name: clicker_display_name.to_owned(),
            created_at: interaction.created_at,
            values: input.values.clone(),
            fields: input.fields.clone(),
            origin_interaction_id: input.origin_id.map(|id| id.to_string()),
        }
    }
}
