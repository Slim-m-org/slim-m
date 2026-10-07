// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Which kinds of client a user is connected from, carried on the live
//! presence entry and never stored.
//!
//! The kind is whatever the client says in its `hello`, not something read
//! off a User-Agent or a device name. A client that names none (an older
//! build) or names one this server does not know is [`DeviceKind::Unknown`],
//! reported as such so a viewer never infers "phone only" from a socket it
//! could not classify.

use super::{PresenceTracker, Status, lock};
use crate::ids::UserId;

/// A coarse class of client, in the order [`PresenceTracker::devices_visible_at`] reports.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceKind {
    Mobile,
    Desktop,
    Web,
    Unknown,
}

impl DeviceKind {
    const ALL: [DeviceKind; 4] = [Self::Mobile, Self::Desktop, Self::Web, Self::Unknown];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Mobile => "mobile",
            Self::Desktop => "desktop",
            Self::Web => "web",
            Self::Unknown => "unknown",
        }
    }

    /// From the `client_kind` a device recorded at sign-in. iOS and Android
    /// are both [`Self::Mobile`]; anything unrecognised, or absent (a session
    /// older than the column), is [`Self::Unknown`] rather than a guess.
    pub fn from_client_kind(value: Option<&str>) -> Self {
        match value {
            Some("ios" | "android") => Self::Mobile,
            Some("desktop") => Self::Desktop,
            Some("web") => Self::Web,
            _ => Self::Unknown,
        }
    }

    const fn slot(self) -> usize {
        self as usize
    }
}

/// How many live sockets of each [`DeviceKind`] a user holds.
#[derive(Default)]
pub(super) struct DeviceCounts([u32; 4]);

impl DeviceCounts {
    pub(super) fn add(&mut self, kind: DeviceKind) {
        self.0[kind.slot()] += 1;
    }

    pub(super) fn remove(&mut self, kind: DeviceKind) {
        let count = &mut self.0[kind.slot()];
        *count = count.saturating_sub(1);
    }

    /// Which kinds are present, for telling a visible change from a repeat.
    pub(super) fn signature(&self) -> [bool; 4] {
        DeviceKind::ALL.map(|kind| self.0[kind.slot()] > 0)
    }

    fn present(&self) -> Vec<DeviceKind> {
        DeviceKind::ALL
            .into_iter()
            .filter(|kind| self.0[kind.slot()] > 0)
            .collect()
    }
}

impl PresenceTracker {
    /// The kinds of client [target] is connected from that a viewer may be
    /// told: none whenever `status` (already resolved by [`super::status_for`])
    /// reads offline, so a hidden user leaks nothing through the same choke
    /// point their status and activity use.
    pub fn devices_visible_at(&self, target: UserId, status: Status) -> Vec<DeviceKind> {
        if status == Status::Offline {
            return Vec::new();
        }
        lock(&self.state)
            .get(&target)
            .map(|entry| entry.devices.present())
            .unwrap_or_default()
    }
}

impl PresenceTracker {
    /// [`Self::devices_visible_at`] as the names the wire carries.
    pub fn device_names_visible_at(&self, target: UserId, status: Status) -> Vec<&'static str> {
        self.devices_visible_at(target, status)
            .into_iter()
            .map(DeviceKind::as_str)
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_maps_known_names_and_everything_else_to_unknown() {
        assert_eq!(
            DeviceKind::from_client_kind(Some("ios")),
            DeviceKind::Mobile
        );
        assert_eq!(
            DeviceKind::from_client_kind(Some("android")),
            DeviceKind::Mobile
        );
        assert_eq!(DeviceKind::from_client_kind(Some("web")), DeviceKind::Web);
        assert_eq!(
            DeviceKind::from_client_kind(Some("phone")),
            DeviceKind::Unknown
        );
        assert_eq!(DeviceKind::from_client_kind(None), DeviceKind::Unknown);
    }

    #[test]
    fn a_kind_is_reported_until_its_last_socket_closes() {
        let user = UserId::generate();
        let tracker = PresenceTracker::new();
        assert!(tracker.connect_as(user, DeviceKind::Mobile));
        assert!(!tracker.connect_as(user, DeviceKind::Mobile));
        assert!(tracker.connect_as(user, DeviceKind::Desktop));
        assert_eq!(
            tracker.devices_visible_at(user, Status::Online),
            vec![DeviceKind::Mobile, DeviceKind::Desktop]
        );
        assert!(tracker.disconnect_as(user, DeviceKind::Desktop));
        assert!(!tracker.disconnect_as(user, DeviceKind::Mobile));
        assert_eq!(
            tracker.devices_visible_at(user, Status::Online),
            vec![DeviceKind::Mobile]
        );
        assert!(tracker.disconnect_as(user, DeviceKind::Mobile));
        assert!(tracker.devices_visible_at(user, Status::Online).is_empty());
    }

    #[test]
    fn an_offline_reading_hides_every_kind() {
        let user = UserId::generate();
        let tracker = PresenceTracker::new();
        tracker.connect_as(user, DeviceKind::Mobile);
        assert!(tracker.devices_visible_at(user, Status::Offline).is_empty());
    }
}
