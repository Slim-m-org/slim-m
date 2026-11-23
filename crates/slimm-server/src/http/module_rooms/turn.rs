// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! One participant's input, applied: wait for the room's turn, run the
//! module's `@room` with the state it holds, and store and send what it answers.

use super::contract::{self, Answer, RoomKind};
use super::registry::{Held, Refused, RoomKey};
use crate::http::AppState;
use crate::http::error::ApiError;
use crate::http::module_host::surface_for;
use crate::http::module_run::{RunContext, RunKind, RunRequest, run_installed};
use crate::ids::{ChannelId, UserId};
use crate::store::{InstalledModule, now_ms};

/// The room an input is for.
#[derive(Clone, Copy)]
pub(crate) struct Place {
    pub(crate) channel: ChannelId,
    pub(crate) kind: RoomKind,
}

impl Place {
    fn context(self) -> RunContext {
        match self.kind {
            RoomKind::Voice => RunContext {
                channel: None,
                voice_channel: Some(self.channel),
            },
            RoomKind::Channel => RunContext {
                channel: Some(self.channel),
                voice_channel: None,
            },
        }
    }
}

/// How one input ended.
pub(crate) enum Outcome {
    /// The module answered a next state, now stored and sent to the room.
    Applied(Held),
    /// The module refused the input; the room is as it was.
    Rejected(Held, String),
    /// The module failed, timed out or broke the contract; the room is as it was.
    Failed(Held, String),
    /// The room is over, by the module's answer or while this input waited.
    Ended,
}

/// Applies `sent` from `sender` to `module`'s room at `place`, strictly after every input before it.
pub(crate) async fn take(
    state: &AppState,
    module: &InstalledModule,
    place: Place,
    sender: UserId,
    sent: &str,
) -> Result<Outcome, ApiError> {
    let key = RoomKey {
        module_id: module.id.clone(),
        channel_id: place.channel,
    };
    let rooms = state.dock.rooms();
    // A room that ends while this input waits gives way to a fresh one, once.
    for _ in 0..2 {
        let entered = rooms.enter(&key).map_err(refusal)?;
        let _turn = entered.room.take_turn().await;
        let held = entered.room.held();
        if held.ended {
            continue;
        }
        let input = contract::input(
            (place.channel, place.kind),
            (held.seq, held.state.as_ref()),
            sent,
        );
        let request = RunRequest {
            caller: sender,
            command: contract::COMMAND,
            input: &input,
            kind: RunKind::Room,
            context: place.context(),
        };
        let surface = surface_for(state, module, sender, None);
        let ran = run_installed(state, module, &request, surface).await?;
        if !ran.ok {
            return Ok(Outcome::Failed(held, ran.payload));
        }
        return Ok(match contract::answer(&ran.payload) {
            Ok(Answer::Next(next)) => {
                let announce =
                    |stored: &Held| super::lifecycle::announce(state, &key, stored, None);
                match entered.room.commit(next, now_ms(), announce) {
                    Some(stored) => Outcome::Applied(stored),
                    None => Outcome::Ended,
                }
            }
            Ok(Answer::Reject(reason)) => Outcome::Rejected(held, reason),
            Ok(Answer::End) => {
                super::lifecycle::end_where(state, |k, _| *k == key, "ended");
                Outcome::Ended
            }
            Err(why) => Outcome::Failed(held, why),
        });
    }
    Ok(Outcome::Ended)
}

fn refusal(refused: Refused) -> ApiError {
    match refused {
        Refused::Busy => ApiError::TooManyRequests,
        Refused::TooManyRooms => {
            ApiError::Conflict("this module already keeps as many rooms as it may")
        }
    }
}
