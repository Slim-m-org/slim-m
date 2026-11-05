// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The add-on API this host speaks and the version of each contract inside it
//! (decision 0100). A module declares the range of `addon_api` it works with;
//! a host outside that range never loads it, so a core change cannot silently
//! break an installed module.

/// The add-on API level: 1 is the module platform (0091), 2 adds private scenes (0099), 3 adds hooks (0100), 4 adds call audio (0105), 5 adds the richer events (0107).
pub const ADDON_API: u32 = 5;
/// The shape of an `@event` input.
pub const EVENT_CONTRACT: u32 = 1;
/// The shape of a `@slot` reply (`slot/1`).
pub const SLOT_CONTRACT: u32 = 1;
/// The shape of an `@intercept` input and reply.
pub const INTERCEPTOR_CONTRACT: u32 = 1;
/// The shape of an `@allow` input and reply.
pub const PERMISSION_HOOK_CONTRACT: u32 = 1;

/// Why a module declaring `min` to `max` cannot run on this host, or `Ok`.
pub fn check_compatible(min: u32, max: Option<u32>) -> Result<(), String> {
    if min > ADDON_API {
        return Err(format!(
            "this module needs add-on API {min}, but this server supports up to {ADDON_API}; update the server"
        ));
    }
    match max {
        Some(max) if max < ADDON_API => Err(format!(
            "this module supports add-on API up to {max}, but this server speaks {ADDON_API}; update the module"
        )),
        _ => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_host_must_sit_inside_the_declared_range() {
        assert!(check_compatible(0, None).is_ok());
        assert!(check_compatible(1, Some(ADDON_API)).is_ok());
        assert!(check_compatible(ADDON_API, Some(ADDON_API + 3)).is_ok());
        let newer = check_compatible(ADDON_API + 1, None).unwrap_err();
        assert!(newer.contains("update the server"), "{newer}");
        let older = check_compatible(1, Some(ADDON_API - 1)).unwrap_err();
        assert!(older.contains("update the module"), "{older}");
    }
}
