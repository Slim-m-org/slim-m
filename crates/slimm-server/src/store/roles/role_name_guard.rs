// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A role name no other role already reads as, checked inside the write that sets it so two
//! managers naming roles alike at once cannot both pass.

use sqlx::SqliteConnection;

use crate::ids::RoleId;

/// What a member would read a role name as, whatever its case, width, invisible marks or a leading `@`.
pub fn fold_role_name(name: &str) -> String {
    crate::hidden_chars::fold_name(name)
}

/// Whether another role already reads as `name`; a role keeping its own folded name never collides,
/// so a role named before this rule can still be edited by a client that resends its name.
pub(in crate::store) async fn name_taken(
    conn: &mut SqliteConnection,
    name: &str,
    role_id: RoleId,
) -> sqlx::Result<bool> {
    let folded = fold_role_name(name);
    let rows = sqlx::query!(r#"SELECT id AS "id!: RoleId", name FROM roles"#)
        .fetch_all(&mut *conn)
        .await?;
    if rows
        .iter()
        .any(|r| r.id == role_id && fold_role_name(&r.name) == folded)
    {
        return Ok(false);
    }
    Ok(rows
        .iter()
        .any(|r| r.id != role_id && fold_role_name(&r.name) == folded))
}
