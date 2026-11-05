// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who hears that a voice call started, grew or went live, and why each exclusion is there
//! (decision 0107).
//!
//! Opt-in per member and per channel. Everything that could make a notice unwelcome is
//! settled here, once, before anything is sent: the in-app frame and the push both start from
//! the audience this returns.

use std::collections::HashSet;

use crate::ids::{ChannelId, UserId};
use crate::notification_schedule::degrade_for_off_hours;
use crate::notifications::NotificationPreference;
use crate::presence::Visibility;
use crate::store::Store;

/// How much of a call's comings and goings a member wants to hear about.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum JoinMode {
    #[default]
    Off,
    /// Only the join that starts the call, into an empty channel.
    First,
    Every,
}

impl JoinMode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Off => "off",
            Self::First => "first",
            Self::Every => "every",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Some(match value {
            "off" => Self::Off,
            "first" => Self::First,
            "every" => Self::Every,
            _ => return None,
        })
    }
}

/// One member's choice for one voice channel.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct VoiceNotifyChoice {
    pub joins: JoinMode,
    pub streams: bool,
}

impl VoiceNotifyChoice {
    pub fn is_off(self) -> bool {
        self.joins == JoinMode::Off && !self.streams
    }

    pub fn wants(self, activity: Activity) -> bool {
        match activity {
            Activity::CallStarted => self.joins != JoinMode::Off,
            Activity::Joined => self.joins == JoinMode::Every,
            Activity::Streaming => self.streams,
        }
    }
}

/// What happened on the call.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Activity {
    /// The first person joined an empty channel.
    CallStarted,
    /// Someone joined a call already under way.
    Joined,
    /// Someone started sharing their screen.
    Streaming,
}

impl Activity {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::CallStarted => "call_started",
            Self::Joined => "joined",
            Self::Streaming => "streaming",
        }
    }
}

/// What the audience is worked out for.
pub struct Event<'a> {
    pub channel_id: ChannelId,
    pub actor: UserId,
    pub activity: Activity,
    /// Who is on the call right now, who needs no telling.
    pub present: &'a [UserId],
    pub now_ms: i64,
}

/// Members to tell about `event`, before the per-recipient time limit.
///
/// Left out: the actor, anyone already on the call, anyone who blocked the actor, anyone who
/// cannot see the channel, anyone on Do not disturb, a muted channel or account, and anyone
/// whose notification schedule is off hours. Nothing at all when the actor is a bot or has
/// chosen to appear offline, since a hidden member's join must not announce them.
pub async fn audience(store: &Store, event: &Event<'_>) -> anyhow::Result<Vec<UserId>> {
    let Event {
        channel_id,
        actor,
        activity,
        present,
        now_ms,
    } = *event;
    let Some(channel) = store.channel(channel_id).await? else {
        return Ok(Vec::new());
    };
    if channel.kind != "voice" || channel.parent_message_id.is_some() {
        return Ok(Vec::new());
    }
    if store.presence_visibility(actor).await? == Some(Visibility::Hidden)
        || store.is_bot(actor).await?
    {
        return Ok(Vec::new());
    }

    let on_call: HashSet<UserId> = present.iter().copied().collect();
    let blockers: HashSet<UserId> = store.blockers_of(actor).await?.into_iter().collect();
    let candidates: Vec<UserId> = store
        .voice_notify_members(channel_id)
        .await?
        .into_iter()
        .filter(|(user, choice)| {
            *user != actor
                && choice.wants(activity)
                && !on_call.contains(user)
                && !blockers.contains(user)
        })
        .map(|(user, _)| user)
        .collect();
    let viewers = store.viewers_among(channel_id, &candidates).await?;
    if viewers.is_empty() {
        return Ok(viewers);
    }

    let visibility = store.presence_visibility_many(&viewers).await?;
    let choices = store
        .channel_notification_choices(channel_id, None, &viewers)
        .await?;
    let schedules = store.notification_schedules_for_users(&viewers).await?;
    let off_hours_ok = store
        .viewers_allowing_channel_off_hours(&viewers, channel_id, None)
        .await?;
    Ok(viewers
        .into_iter()
        .filter(|user| visibility.get(user) != Some(&Visibility::Dnd))
        .filter(|user| {
            choices.get(user).map(|choice| choice.preference)
                != Some(NotificationPreference::Nothing)
        })
        .filter(|user| {
            let Some(schedule) = schedules.get(user) else {
                return true;
            };
            degrade_for_off_hours(
                NotificationPreference::Everything,
                schedule.evaluate(now_ms),
                off_hours_ok.contains(user),
                false,
            ) == NotificationPreference::Everything
        })
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_join_mode_hears_a_call_start_but_not_a_later_join() {
        let first = VoiceNotifyChoice {
            joins: JoinMode::First,
            streams: false,
        };
        assert!(first.wants(Activity::CallStarted));
        assert!(!first.wants(Activity::Joined));
        assert!(!first.wants(Activity::Streaming));
    }

    #[test]
    fn every_join_hears_both_and_streaming_is_its_own_switch() {
        let every = VoiceNotifyChoice {
            joins: JoinMode::Every,
            streams: false,
        };
        assert!(every.wants(Activity::CallStarted) && every.wants(Activity::Joined));
        assert!(!every.wants(Activity::Streaming));
        let streams = VoiceNotifyChoice {
            joins: JoinMode::Off,
            streams: true,
        };
        assert!(streams.wants(Activity::Streaming));
        assert!(!streams.wants(Activity::CallStarted));
    }

    #[test]
    fn off_and_no_streams_is_off() {
        assert!(VoiceNotifyChoice::default().is_off());
    }
}
