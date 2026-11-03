// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One module hearing one call, as a pure state machine (decision 0105).
//!
//! Nothing here touches the clock, the network or the database: every
//! transition takes `now` in milliseconds and returns the effects the caller
//! must carry out. The one rule everything protects is that the include set
//! holds only people who said yes, and never more than [`MAX_INCLUDED`].

use std::collections::BTreeMap;

use uuid::Uuid;

use crate::ids::{ChannelId, UserId};

/// People one session can hold, asked or included.
pub const MAX_INCLUDED: usize = 25;
/// How long everyone has to answer.
pub const ASK_WINDOW_MS: i64 = 60_000;
/// How long a session may run.
pub const TIME_LIMIT_MS: i64 = 4 * 60 * 60 * 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Answer {
    Yes,
    Pending,
    No,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Asking,
    On,
}

/// Why a session ended. `Lapsed` is the answer window running out, which a
/// module (told only when a session was on) never sees apart from `declined`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndReason {
    Stopped,
    Declined,
    Lapsed,
    CallEnded,
    TimeLimit,
    Overload,
    ModuleDisabled,
    ChannelRemoved,
    ListenerUnavailable,
}

impl EndReason {
    /// The name a module and a client are given.
    pub fn wire(self) -> &'static str {
        match self {
            Self::Stopped => "stopped",
            Self::Declined | Self::Lapsed => "declined",
            Self::CallEnded => "call_ended",
            Self::TimeLimit => "time_limit",
            Self::Overload => "overload",
            Self::ModuleDisabled => "module_disabled",
            Self::ChannelRemoved => "channel_removed",
            Self::ListenerUnavailable => "listener_unavailable",
        }
    }

    /// Whether a person turned it down or let it lapse, which starts a cooldown.
    pub fn is_refusal(self) -> bool {
        matches!(self, Self::Declined | Self::Lapsed | Self::Stopped)
    }
}

/// What the caller must do after a transition.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Effect {
    /// Asking became on: start the listener with the current include set.
    Start,
    /// The include set changed while on: send the whole set again.
    Include,
    /// Someone entered or left the include set while on.
    Participant { user_id: UserId, included: bool },
    /// The session is over; `was_on` says whether the listener and module ever heard of it.
    Ended { reason: EndReason, was_on: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Refused {
    NotInCall,
}

/// What a person is shown about the module.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subject {
    pub module_id: String,
    pub module_name: String,
    pub purpose: String,
    pub keeps: String,
}

#[derive(Debug, Clone)]
pub struct Session {
    pub id: Uuid,
    pub channel: ChannelId,
    pub subject: Subject,
    pub requested_by: UserId,
    pub status: Status,
    pub expires_at_ms: i64,
    pub started_at_ms: Option<i64>,
    answers: BTreeMap<UserId, Answer>,
}

impl Session {
    /// A request from `requester`, who is among `present`. Everyone else is asked.
    /// Returns `None` when the call is too large to hold; the session is already
    /// on, with `Effect::Start`, when the requester is alone.
    pub fn request(
        (id, channel, subject): (Uuid, ChannelId, Subject),
        requester: UserId,
        present: &[UserId],
        now: i64,
    ) -> Option<(Self, Vec<Effect>)> {
        let mut answers: BTreeMap<UserId, Answer> =
            present.iter().map(|u| (*u, Answer::Pending)).collect();
        answers.insert(requester, Answer::Yes);
        if answers.len() > MAX_INCLUDED {
            return None;
        }
        let mut session = Self {
            id,
            channel,
            subject,
            requested_by: requester,
            status: Status::Asking,
            expires_at_ms: now + ASK_WINDOW_MS,
            started_at_ms: None,
            answers,
        };
        let effects = session.start_if_unanimous(now);
        Some((session, effects))
    }

    /// Everyone who said yes, in a stable order: the only people the listener may hear.
    pub fn include(&self) -> Vec<UserId> {
        self.with_answer(Answer::Yes)
    }

    /// Everyone who has not answered.
    pub fn pending(&self) -> Vec<UserId> {
        self.with_answer(Answer::Pending)
    }

    pub fn answer_of(&self, user: UserId) -> Option<Answer> {
        self.answers.get(&user).copied()
    }

    /// Whether the call holds more people than a session can ask.
    pub fn is_full(&self) -> bool {
        self.answers.len() >= MAX_INCLUDED
    }

    fn with_answer(&self, wanted: Answer) -> Vec<UserId> {
        self.answers
            .iter()
            .filter(|(_, a)| **a == wanted)
            .map(|(u, _)| *u)
            .collect()
    }

    fn unanimous(&self) -> bool {
        !self.answers.is_empty() && self.answers.values().all(|a| *a == Answer::Yes)
    }

    fn start_if_unanimous(&mut self, now: i64) -> Vec<Effect> {
        if self.status == Status::Asking && self.unanimous() {
            self.status = Status::On;
            self.started_at_ms = Some(now);
            return vec![Effect::Start];
        }
        Vec::new()
    }

    fn end(&self, reason: EndReason) -> Vec<Effect> {
        vec![Effect::Ended {
            reason,
            was_on: self.status == Status::On,
        }]
    }

    /// `user` answers. A no ends the session for everyone, whoever says it.
    pub fn consent(&mut self, user: UserId, allow: bool, now: i64) -> Result<Vec<Effect>, Refused> {
        let Some(answer) = self.answers.get_mut(&user) else {
            return Err(Refused::NotInCall);
        };
        if !allow {
            *answer = Answer::No;
            return Ok(self.end(EndReason::Declined));
        }
        if *answer == Answer::Yes {
            return Ok(Vec::new());
        }
        *answer = Answer::Yes;
        let mut effects = self.start_if_unanimous(now);
        if self.status == Status::On && effects.is_empty() {
            effects.push(Effect::Participant {
                user_id: user,
                included: true,
            });
            effects.push(Effect::Include);
        }
        Ok(effects)
    }

    /// `user` joined the call. They are left out until they say yes.
    pub fn join(&mut self, user: UserId) -> Vec<Effect> {
        if self.answers.contains_key(&user) || self.is_full() {
            return Vec::new();
        }
        self.answers.insert(user, Answer::Pending);
        Vec::new()
    }

    /// `user` left the call.
    pub fn leave(&mut self, user: UserId, now: i64) -> Vec<Effect> {
        let Some(was) = self.answers.remove(&user) else {
            return Vec::new();
        };
        if self.answers.is_empty() {
            return self.end(EndReason::CallEnded);
        }
        match self.status {
            Status::On if self.include().is_empty() => self.end(EndReason::CallEnded),
            Status::On if was == Answer::Yes => vec![
                Effect::Participant {
                    user_id: user,
                    included: false,
                },
                Effect::Include,
            ],
            Status::On => Vec::new(),
            Status::Asking if user == self.requested_by => self.end(EndReason::Stopped),
            Status::Asking => self.start_if_unanimous(now),
        }
    }

    /// Anyone in the call stops it for everyone.
    pub fn stop(&self, user: UserId) -> Result<Vec<Effect>, Refused> {
        if !self.answers.contains_key(&user) {
            return Err(Refused::NotInCall);
        }
        Ok(self.end(EndReason::Stopped))
    }

    /// Time passing: the ask lapses, the session reaches its limit.
    pub fn tick(&self, now: i64) -> Vec<Effect> {
        match self.status {
            Status::Asking if now >= self.expires_at_ms => self.end(EndReason::Lapsed),
            Status::On
                if self
                    .started_at_ms
                    .is_some_and(|at| now - at >= TIME_LIMIT_MS) =>
            {
                self.end(EndReason::TimeLimit)
            }
            _ => Vec::new(),
        }
    }

    /// Something outside the session ended it.
    pub fn force_end(&self, reason: EndReason) -> Vec<Effect> {
        self.end(reason)
    }
}

#[cfg(test)]
mod tests;
