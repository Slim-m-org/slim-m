// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The `room/1` contract (decision 0131): the `@room` input the host sends a
//! module, and the three answers it accepts back.

use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;

use crate::hub::RoomJson;
use crate::ids::ChannelId;

/// The command a room input runs.
pub(crate) const COMMAND: &str = "@room";
const CONTRACT: &str = "room/1";
/// The most bytes a participant's input may hold.
pub(crate) const MAX_INPUT_BYTES: usize = 1024;
/// The most bytes a room's state may hold, as the module wrote it.
pub(crate) const MAX_STATE_BYTES: usize = 16 * 1024;
/// The most characters of a refusal a sender is shown.
const MAX_REASON_CHARS: usize = 200;

/// The two kinds of room: a voice call, or a text channel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RoomKind {
    Voice,
    Channel,
}

impl RoomKind {
    fn name(self) -> &'static str {
        match self {
            Self::Voice => "voice",
            Self::Channel => "channel",
        }
    }
}

#[derive(Serialize)]
struct Input<'a> {
    #[serde(rename = "$slim")]
    slim: &'static str,
    room: Room,
    seq: u64,
    state: Option<&'a RoomJson>,
    input: &'a str,
}

#[derive(Serialize)]
struct Room {
    channel_id: String,
    kind: &'static str,
}

/// The `input` text of one `@room` run.
pub(crate) fn input(
    (channel, kind): (ChannelId, RoomKind),
    (seq, state): (u64, Option<&RoomJson>),
    sent: &str,
) -> String {
    serde_json::to_string(&Input {
        slim: CONTRACT,
        room: Room {
            channel_id: channel.to_string(),
            kind: kind.name(),
        },
        seq,
        state,
        input: sent,
    })
    .unwrap_or_default()
}

#[derive(Deserialize)]
struct Reply {
    #[serde(rename = "$slim")]
    slim: String,
    #[serde(default)]
    state: Option<Box<RawValue>>,
    #[serde(default)]
    reject: Option<String>,
    #[serde(default)]
    end: bool,
}

/// What a module asked the room to do with one input.
#[derive(Debug)]
pub(crate) enum Answer {
    /// The next state, to store and send to everyone in the room.
    Next(RoomJson),
    /// The input is refused; the state stays, and the sender is told why.
    Reject(String),
    /// The room is over.
    End,
}

/// The module's answer, or why it breaks the contract.
pub(crate) fn answer(output: &str) -> Result<Answer, String> {
    let reply: Reply = serde_json::from_str(output).map_err(|_| "reply is not a room/1 answer")?;
    if reply.slim != CONTRACT {
        return Err("reply is not tagged room/1".into());
    }
    match (reply.state, reply.reject, reply.end) {
        (Some(state), None, false) if state.get().len() <= MAX_STATE_BYTES => {
            Ok(Answer::Next(RoomJson::new(state)))
        }
        (Some(_), None, false) => Err(format!("state is over {MAX_STATE_BYTES} bytes")),
        (None, Some(reason), false) => Ok(Answer::Reject(
            reason.chars().take(MAX_REASON_CHARS).collect(),
        )),
        (None, None, true) => Ok(Answer::End),
        _ => Err("reply must carry exactly one of state, reject or end".into()),
    }
}

#[cfg(test)]
mod tests;
