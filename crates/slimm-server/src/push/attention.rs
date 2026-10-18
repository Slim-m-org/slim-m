// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Drops push recipients who have already seen a message on another device.
//!
//! Runs after [`super::message_recipients`] so its permission, block,
//! preference and schedule rules stay untouched; this only ever removes
//! people, never adds one. Three independent signals, any is enough:
//!
//! - the recipient's account-level read marker already covers the message,
//!   which is what a device that read it, or a send from another device,
//!   leaves behind; and
//! - one of their connections reports the channel open and focused right now
//!   (`ViewingTracker`), which covers the window before that device has had a
//!   chance to advance the marker for a message that has only just landed; or
//! - they used one of their devices within `viewing::ACTIVE_WINDOW`, so the
//!   message is already in front of them there and a phone push only repeats it.
//!   Calls and security alerts take other paths and are never narrowed here.
//!
//! Neither is exposed to anyone else: the result only shortens this one push.

use std::fmt;
use std::time::Instant;

use crate::ids::{ChannelId, DeviceId, Seq, UserId};
use crate::store::Store;
use crate::viewing::ViewingTracker;

/// Why one recipient was left out of a push, with the devices behind the signal where there are any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SkipReason {
    Read,
    Viewing(Vec<DeviceId>),
    RecentlyActive(Vec<DeviceId>),
}

/// Every reason that applies, in the order they are checked; empty means the recipient is pushed.
pub fn skip_reasons(
    covered: bool,
    viewing: Vec<DeviceId>,
    active: Vec<DeviceId>,
) -> Vec<SkipReason> {
    let mut reasons = Vec::new();
    if covered {
        reasons.push(SkipReason::Read);
    }
    if !viewing.is_empty() {
        reasons.push(SkipReason::Viewing(viewing));
    }
    if !active.is_empty() {
        reasons.push(SkipReason::RecentlyActive(active));
    }
    reasons
}

/// The recipients that stay, and why each of the others went.
pub struct Narrowed {
    pub kept: Vec<UserId>,
    pub skipped: Vec<(UserId, Vec<SkipReason>)>,
}

/// One log line's worth of skip counts for a single push event, never any content or token.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SkipSummary {
    pub read: usize,
    pub viewing: usize,
    pub recently_active: usize,
    pub foreground_device: usize,
    pub debounced: usize,
    pub users: Vec<UserId>,
    /// Device and age in ms of each foreground report that silenced a recipient.
    /// The device ids behind each viewing or recently-active skip, as `kind:device`.
    pub signal_devices: Vec<String>,
    pub foreground_reports: Vec<(DeviceId, Option<i64>)>,
}

impl SkipSummary {
    pub fn is_empty(&self) -> bool {
        self.users.is_empty()
    }

    /// Counts a recipient by its first reason, the one that decided the skip.
    pub fn note(&mut self, user: UserId, reasons: &[SkipReason]) {
        match reasons.first() {
            Some(SkipReason::Read) => self.read += 1,
            Some(SkipReason::Viewing(devices)) => {
                self.viewing += 1;
                self.signal_devices
                    .extend(devices.iter().map(|d| format!("viewing:{d}")));
            }
            Some(SkipReason::RecentlyActive(devices)) => {
                self.recently_active += 1;
                self.signal_devices
                    .extend(devices.iter().map(|d| format!("active:{d}")));
            }
            None => return,
        }
        self.users.push(user);
    }

    pub fn note_foreground_device(&mut self, user: UserId, device: DeviceId, age_ms: Option<i64>) {
        self.foreground_device += 1;
        self.users.push(user);
        self.foreground_reports.push((device, age_ms));
    }

    pub fn note_debounced(&mut self, user: UserId) {
        self.debounced += 1;
        self.users.push(user);
    }
}

impl fmt::Display for SkipSummary {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "read={} viewing={} recently_active={} foreground_device={} debounced={}",
            self.read, self.viewing, self.recently_active, self.foreground_device, self.debounced
        )
    }
}

/// `seq` is the message's own seq in `channel_id`.
pub async fn narrow_for_attention(
    store: &Store,
    channel_id: ChannelId,
    seq: Seq,
    viewing: &ViewingTracker,
    recipients: Vec<UserId>,
) -> anyhow::Result<Vec<UserId>> {
    Ok(
        narrow_with_reasons(store, channel_id, seq, viewing, recipients)
            .await?
            .kept,
    )
}

pub async fn narrow_with_reasons(
    store: &Store,
    channel_id: ChannelId,
    seq: Seq,
    viewing: &ViewingTracker,
    recipients: Vec<UserId>,
) -> anyhow::Result<Narrowed> {
    let mut narrowed = Narrowed {
        kept: Vec::new(),
        skipped: Vec::new(),
    };
    if recipients.is_empty() {
        return Ok(narrowed);
    }
    let read = store.last_read_seqs(channel_id, &recipients).await?;
    let now = Instant::now();
    for user_id in recipients {
        let covered = read.get(&user_id).is_some_and(|last| *last >= seq.0);
        let reasons = skip_reasons(
            covered,
            viewing.viewing_devices_at(user_id, channel_id, now),
            viewing.active_devices_at(user_id, now),
        );
        if reasons.is_empty() {
            narrowed.kept.push(user_id);
        } else {
            narrowed.skipped.push((user_id, reasons));
        }
    }
    Ok(narrowed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recipient_nobody_is_covering_is_pushed() {
        assert!(skip_reasons(false, vec![], vec![]).is_empty());
    }

    #[test]
    fn every_applicable_reason_is_named_with_its_devices() {
        let (phone, laptop) = (DeviceId::generate(), DeviceId::generate());
        assert_eq!(
            skip_reasons(true, vec![laptop], vec![phone]),
            vec![
                SkipReason::Read,
                SkipReason::Viewing(vec![laptop]),
                SkipReason::RecentlyActive(vec![phone]),
            ]
        );
    }

    #[test]
    fn the_summary_counts_the_deciding_reason_once_per_recipient() {
        let mut summary = SkipSummary::default();
        let user = UserId::generate();
        summary.note(
            user,
            &skip_reasons(true, vec![DeviceId::generate()], vec![]),
        );
        summary.note(UserId::generate(), &[]);
        summary.note_foreground_device(UserId::generate(), DeviceId::generate(), Some(5_000));
        summary.note_debounced(UserId::generate());
        assert_eq!(
            summary.to_string(),
            "read=1 viewing=0 recently_active=0 foreground_device=1 debounced=1"
        );
        assert_eq!(summary.users.len(), 3);
    }
}
