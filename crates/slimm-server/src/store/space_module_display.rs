// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Where module output shows for every member of the Space.

use anyhow::Context;

use super::{Store, now_ms};

/// The two display switches an admin sets for the whole Space.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ModuleDisplay {
    pub member_badges: bool,
    pub profile_sections: bool,
}

impl Default for ModuleDisplay {
    fn default() -> Self {
        Self {
            member_badges: false,
            profile_sections: true,
        }
    }
}

impl Store {
    pub async fn module_display(&self) -> anyhow::Result<ModuleDisplay> {
        let row = sqlx::query!(
            r#"SELECT module_member_badges AS "badges!: bool",
                      module_profile_sections AS "sections!: bool"
               FROM space_settings WHERE id = 1"#
        )
        .fetch_optional(&self.pool)
        .await
        .context("read module display settings")?;
        Ok(row.map_or_else(ModuleDisplay::default, |r| ModuleDisplay {
            member_badges: r.badges,
            profile_sections: r.sections,
        }))
    }

    /// Writes only the switches given.
    pub async fn set_module_display(
        &self,
        member_badges: Option<bool>,
        profile_sections: Option<bool>,
    ) -> anyhow::Result<()> {
        let now = now_ms();
        sqlx::query!(
            "UPDATE space_settings
             SET module_member_badges = COALESCE(?, module_member_badges),
                 module_profile_sections = COALESCE(?, module_profile_sections),
                 updated_at = ?
             WHERE id = 1",
            member_badges,
            profile_sections,
            now
        )
        .execute(&self.pool)
        .await
        .context("set module display settings")?;
        Ok(())
    }
}
