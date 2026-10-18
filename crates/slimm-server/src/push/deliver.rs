// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The background half of [`super::PushSender::notify_message`]: resolves
//! recipients, applies the per-recipient debounce, seals an envelope per
//! target, and calls the relay.
//!
//! Split out of `push.rs` to keep that file under the file-budget hard
//! ceiling rather than for any reason about what belongs where; every item
//! here is still `push`-private and reachable only through `super::`.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::ids::{ChannelId, UserId};
use crate::store::{Store, now_ms};

use super::attention::{SkipReason, SkipSummary, narrow_with_reasons};
use super::debounce::Debounce;
use super::recipients::message_audience;
use super::{Enabled, SentMessage, dispatch, envelope};

/// How long a device's `foreground` report counts as still current, the same
/// window a websocket viewing report gets. Past this
/// the app could have backgrounded or been killed without a fresh report (the
/// process was simply suspended, for instance), so treat the state as stale
/// and push anyway rather than risk a silent notification gap.
const FOREGROUND_FRESHNESS_MS: i64 = crate::viewing::FOREGROUND_FRESHNESS.as_millis() as i64;

/// Every error path logs and returns rather than propagating: there is no
/// caller left to report to, only the process log.
///
/// The recipient rule lives in [`super::message_recipients`], including why the author
/// and anybody who blocked them are dropped.
///
/// The debounce is decided once per recipient, even when they have several
/// registered devices, so a second device is never mistaken for a second burst
/// trigger and dropped. A recipient filtered out for being foreground never
/// reaches that decision, so their state can never cost a different recipient
/// (or their own next genuine message) a wake; see the module docs and
/// [`Debounce`].
///
/// A window only stays shut when a recipient was really woken, which means at
/// least one of their devices took the push. Everything else releases it: a
/// batch that failed at the transport level, a recipient whose devices all
/// failed to seal (most likely a corrupt stored key), and the relay's
/// forbidden, error and not_attempted statuses. Treating any of those as
/// success would suppress that recipient's next genuine message, turning a
/// dropped wake into a silently missing notification.
///
/// A status this server does not recognize means the two repos have drifted on
/// the status vocabulary. It is handled as any other inactionable status rather
/// than crashing or misrouting, but logged, since it should never happen
/// against a relay built from the documented contract.
pub(super) async fn deliver(
    enabled: Arc<Enabled>,
    debounce: Arc<Debounce>,
    store: Store,
    sent: SentMessage,
) {
    let channel_id = sent.channel_id;
    let mut skips = SkipSummary::default();
    deliver_inner(enabled, debounce, store, sent, &mut skips).await;
    log_skips(channel_id, &skips);
}

/// One info line per push event naming who was left out and why, so "no notification" is diagnosable from the log.
fn log_skips(channel_id: ChannelId, skips: &SkipSummary) {
    if skips.is_empty() {
        return;
    }
    let users: Vec<String> = skips.users.iter().map(ToString::to_string).collect();
    let foreground: Vec<String> = skips
        .foreground_reports
        .iter()
        .map(|(device, age_ms)| format!("{device}:{}ms", age_ms.unwrap_or(-1)))
        .collect();
    tracing::info!(
        %channel_id, %skips, users = %users.join(","), foreground = %foreground.join(","),
        devices = %skips.signal_devices.join(","),
        "push: recipients skipped"
    );
}

fn log_skip_detail(channel_id: ChannelId, user_id: UserId, reasons: &[SkipReason]) {
    tracing::debug!(%channel_id, %user_id, ?reasons, "push: recipient skipped");
}

async fn deliver_inner(
    enabled: Arc<Enabled>,
    debounce: Arc<Debounce>,
    store: Store,
    sent: SentMessage,
    skips: &mut SkipSummary,
) {
    let SentMessage {
        channel_id,
        author_id,
        message_id,
        seq,
        content,
        presence,
        reply_ping,
    } = sent;
    let (recipients, mentioned) = match message_audience(
        &store, channel_id, author_id, &content, &presence, reply_ping,
    )
    .await
    {
        Ok(audience) => audience,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to resolve recipients");
            return;
        }
    };
    let narrowed =
        match narrow_with_reasons(&store, channel_id, seq, &presence.viewing(), recipients).await {
            Ok(narrowed) => narrowed,
            Err(err) => {
                tracing::warn!(error = %err, %channel_id, "push: failed to read attention state");
                return;
            }
        };
    for (user_id, reasons) in &narrowed.skipped {
        skips.note(*user_id, reasons);
        log_skip_detail(channel_id, *user_id, reasons);
    }
    let recipients = narrowed.kept;
    if recipients.is_empty() {
        return;
    }

    let targets = match store.push_targets(&recipients).await {
        Ok(targets) => targets,
        Err(err) => {
            tracing::warn!(error = %err, %channel_id, "push: failed to load push targets");
            return;
        }
    };

    let now = now_ms();
    let (foreground, targets): (Vec<_>, Vec<_>) = targets
        .into_iter()
        .partition(|target| is_foreground_and_recent(target, now));
    let still_targeted: HashSet<UserId> = targets.iter().map(|t| t.user_id).collect();
    let mut silenced = HashSet::new();
    for target in &foreground {
        if still_targeted.contains(&target.user_id) || !silenced.insert(target.user_id) {
            continue;
        }
        let age_ms = target.lifecycle_reported_at.map(|at| now - at);
        skips.note_foreground_device(target.user_id, target.device_id, age_ms);
    }
    if targets.is_empty() {
        return;
    }

    // Once per recipient, not once per device; see the note on this function.
    let mut decisions: HashMap<UserId, Option<i64>> = HashMap::new();
    for target in &targets {
        decisions.entry(target.user_id).or_insert_with(|| {
            debounce.try_fire(
                channel_id,
                target.user_id,
                mentioned.contains(&target.user_id),
            )
        });
    }
    let opened: HashMap<UserId, i64> = decisions
        .into_iter()
        .filter_map(|(user_id, fired_at)| {
            if fired_at.is_none() {
                skips.note_debounced(user_id);
            }
            fired_at.map(|fired_at| (user_id, fired_at))
        })
        .collect();
    let targets: Vec<_> = targets
        .into_iter()
        .filter(|target| opened.contains_key(&target.user_id))
        .collect();
    if targets.is_empty() {
        return;
    }

    // Only when a device actually asked, so nobody opting in costs nothing.
    let preview = if targets.iter().any(|target| target.include_content) {
        let text = super::preview_text::preview_text(&store, message_id, &content).await;
        message_preview(&store, channel_id, author_id, &text).await
    } else {
        None
    };

    // Read fresh here, not reused from the `now` above: sealing is what this timestamp defends.
    let sent_at = now_ms();
    let messages = envelope::seal_for_message(
        channel_id,
        message_id,
        seq,
        sent_at,
        preview.as_ref(),
        &targets,
        &mentioned,
    );

    // Nothing sealed means nothing was attempted, so release; see this function's own doc.
    for (&user_id, &fired_at) in &opened {
        if !messages.iter().any(|m| m.user_id == user_id) {
            debounce.release_if_undelivered(channel_id, user_id, fired_at);
        }
    }
    if messages.is_empty() {
        return;
    }

    // Only a Delivered device counts as a wake, and a transport failure releases every window; see this function's doc.
    let delivered = dispatch::send_and_prune(&enabled, &store, &messages, "message")
        .await
        .unwrap_or_default();
    for (&user_id, &fired_at) in &opened {
        if !delivered.contains(&user_id) {
            debounce.release_if_undelivered(channel_id, user_id, fired_at);
        }
    }
}

/// The sender and channel names a content-carrying envelope needs, resolved
/// once for the whole batch.
///
/// One preview serves every recipient because none of it is per-viewer:
/// blocking is already settled further up ([`super::message_recipients`] drops a
/// blocked author's recipients outright rather than filtering their
/// notification afterwards), and a display name and channel name are the same
/// for everybody who can see the message at all.
///
/// `None` on any failure, and on an author or channel that no longer resolves:
/// the envelope simply goes out content-free, which is exactly what every
/// device got before this existed. A preview is a nicety, and it must never be
/// the reason somebody is not woken at all.
async fn message_preview(
    store: &Store,
    channel_id: ChannelId,
    author_id: UserId,
    content: &str,
) -> Option<envelope::MessagePreview> {
    let author = match store.user_profile(author_id).await {
        Ok(Some(author)) => author,
        Ok(None) => return None,
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to resolve the author for a preview");
            return None;
        }
    };
    // A DM's and a thread's channel row both carry an empty name by design.
    let channel_name = match store.channel(channel_id).await {
        Ok(channel) => channel.map(|c| c.name).unwrap_or_default(),
        Err(err) => {
            tracing::warn!(error = %err, "push: failed to resolve the channel for a preview");
            return None;
        }
    };
    Some(envelope::MessagePreview::new(
        &author.display_name,
        &channel_name,
        content,
    ))
}

/// True if a device's most recent lifecycle report says foreground and that
/// report is still fresh. WebSocket presence is deliberately not consulted
/// here: iOS suspends a socket without closing it, so a connected socket is
/// not evidence the app can show anything right now.
///
/// `pub(super)` rather than private: `call_ring.rs`'s own ring push shares
/// this exact check, for the same reason - a foreground app already has the
/// live ring event, so a push would only duplicate what it just showed.
pub(super) fn is_foreground_and_recent(target: &crate::store::PushTarget, now: i64) -> bool {
    let Some(state) = target.lifecycle_state.as_deref() else {
        return false;
    };
    let Some(reported_at) = target.lifecycle_reported_at else {
        return false;
    };
    crate::viewing::is_foreground_label(state) && now - reported_at < FOREGROUND_FRESHNESS_MS
}

#[cfg(test)]
mod tests {
    use super::{FOREGROUND_FRESHNESS_MS, is_foreground_and_recent};
    use crate::ids::{DeviceId, UserId};
    use crate::store::PushTarget;

    fn target(state: Option<&str>, reported_at: Option<i64>) -> PushTarget {
        PushTarget {
            user_id: UserId::generate(),
            device_id: DeviceId::generate(),
            platform: "ios".to_owned(),
            push_token: "t".to_owned(),
            voip_push_token: None,
            push_public_key: Vec::new(),
            lifecycle_state: state.map(str::to_owned),
            lifecycle_reported_at: reported_at,
            include_content: false,
        }
    }

    /// A device that reported itself foreground within the freshness window is
    /// suppressed; one whose report has aged past the window is not, since it
    /// may well be backgrounded by now.
    #[test]
    fn freshness_is_a_half_open_window() {
        let base = 1_000_000;
        let fresh = target(Some("foreground"), Some(base));
        assert!(is_foreground_and_recent(
            &fresh,
            base + FOREGROUND_FRESHNESS_MS - 1
        ));
        // Exactly at the window is already stale: the bound is strict.
        assert!(!is_foreground_and_recent(
            &fresh,
            base + FOREGROUND_FRESHNESS_MS
        ));
    }

    #[test]
    fn only_the_foreground_state_suppresses() {
        let now = 1_000_000;
        assert!(!is_foreground_and_recent(
            &target(Some("background"), Some(now)),
            now
        ));
    }

    /// Missing lifecycle data defaults to *not* suppressing, so an absent or
    /// never-reported state can never silence a push that should fire.
    #[test]
    fn missing_lifecycle_data_never_suppresses() {
        let now = 1_000_000;
        assert!(!is_foreground_and_recent(&target(None, Some(now)), now));
        assert!(!is_foreground_and_recent(
            &target(Some("foreground"), None),
            now
        ));
    }
}
