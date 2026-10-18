// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Gates the bodies the server really sends against the bodies
//! schema/openapi.yaml promises.
//!
//! `tests/openapi_contract.rs` already pins the route surface, but only the
//! method and path of it. Everything inside a response - which fields exist,
//! their types, their nullability, the status code and content type they
//! arrive under - was checked by review alone, on three sides that are all
//! written by hand: the Rust DTO, this schema, and the Dart model in
//! `client/packages/api`. This test removes the schema-to-server half of that
//! gap by driving every documented operation for real and validating the
//! answer against the document.
//!
//! Both directions of drift fail, and deliberately so:
//!
//! - The schema promising a field the server does not send is caught by
//!   `required` in the validator. A client written from the schema would have
//!   read that field.
//! - The server sending a field the schema does not document is caught by the
//!   second pass in `openapi.rs`. The additive-only policy this project holds
//!   is about how the *schema* may evolve between versions so old clients keep
//!   working; it is not a licence for the server to emit fields no client can
//!   know exist, which is precisely how a hand-written Dart model ends up
//!   missing one.
//!
//! Coverage is enumerated, never assumed. Every operationId in the schema must
//! either be exercised below or appear in `UNCOVERED` with a reason, and an
//! entry in `UNCOVERED` that is stale (unknown, or actually covered) fails
//! too. Silence is the one outcome this test must never produce, because a
//! contract test that quietly skips an endpoint reads as assurance while
//! giving none.
//!
//! Refusals are checked too, by `script/refusals.rs`. Until it existed this
//! test returned before the schema was consulted on any non-2xx, so the whole
//! documented error surface - 401 on 158 operations, 403 on 103, 400 on 87,
//! 404 on 50, 409 on 23 - was validated by nothing, and a handler whose error
//! body had drifted from `Error` passed every gate here. One representative
//! case per status rather than one per operation: `Error` is the same object
//! on every route, so the shape is what is bought. The status-to-condition
//! mapping per operation is not, and is not claimed.
//!
//! A refusal deliberately does not count toward `covered`; see
//! `Contract::refuses` for why counting it would let a happy path lapse.

mod openapi;
mod script;
#[path = "../support/mod.rs"]
mod support;
mod verdict;
mod world;

use std::collections::BTreeSet;

use world::Contract;

/// Operations this test cannot drive, each with the reason. Anything not on
/// this list must be called.
const UNCOVERED: &[(&str, &str)] = &[
    (
        "startDiscordLink",
        "needs a configured Discord application, which this fixture's router has \
         none of, so it can only answer 501 here. Its 200 and 501 are covered by \
         tests/discord_link.rs against a local fake of Discord.",
    ),
    (
        "discordLinkCallback",
        "answers HTML to a browser, not JSON, and needs a state minted by \
         startDiscordLink plus a fake Discord to trade the code with; \
         tests/discord_link.rs drives every outcome of it.",
    ),
    (
        "getLinkedDiscordAvatar",
        "answers image bytes, not JSON, and only after a Discord link stored \
         one; tests/discord_link_avatar.rs drives the 200 and the 404.",
    ),
    (
        "inviteLandingPage",
        "answers HTML to a browser, not JSON; tests/invite_page.rs drives both outcomes.",
    ),
    (
        "kickVoiceParticipant",
        "the only path to its 204 goes through a reachable LiveKit room service, \
         which this harness has none of. Nothing is lost by not driving it: the \
         success response is 204 with no body, so there is no shape to check. Its \
         permission gate is covered in tests/voice.rs.",
    ),
    (
        "listVoiceRoster",
        "its 200 also goes through a reachable LiveKit room service, which this \
         harness has none of; the fixture's SFU url is undialable by design (see \
         world.rs). Its shape, the room-not-found-is-empty case, and the \
         appear-offline filter are covered by tests/voice_roster.rs against a real \
         mock room service; its permission gate is covered there too.",
    ),
    (
        "connectWebSocket",
        "an upgrade, not a request/response: the only statuses it documents are 101 and \
     503 and neither carries a body. The frames that flow afterwards are exercised by \
     tests/ws.rs against a real socket.",
    ),
    (
        "getMetrics",
        "its 200 does a real network round trip probing the configured SFU's reachability, \
         same as listVoiceRoster and kickVoiceParticipant above, against this fixture's \
         deliberately undialable wss://sfu.invalid; driving it here would add a real DNS \
         lookup to a test that must not touch the network. The exposition format, every \
         series, the gating, and both reachable/unreachable SFU cases are covered by \
         tests/metrics.rs, which stands up a real (and a deliberately closed) HTTP \
         listener instead.",
    ),
    (
        "diagnosticsDownload",
        "answers raw filler bytes, not JSON; tests/diagnostics.rs drives the size, the cap and the 400.",
    ),
    (
        "diagnosticsUpload",
        "takes a raw byte body this script's JSON helpers cannot send; tests/diagnostics.rs \
         drives the 200, the 413 and the rate limit.",
    ),
    (
        "receiveLiveKitWebhook",
        "authenticated by a signed JWT this fixture's script has no LiveKit key pair to \
         mint, never a session - see docs/decisions/0032-voice-participant-webhooks.md. \
         Its 204/403/501 shapes, the real signature verification, and the fan-out it \
         triggers are covered end to end by tests/live_voice_participant_events.rs and \
         tests/live_voice_screen_share_events.rs against the real handler.",
    ),
];

#[tokio::test]
async fn responses_match_the_schema() {
    let mut contract = Contract::new().await;
    script::run(&mut contract).await;

    let documented = contract.operation_ids();
    let exempt: BTreeSet<String> = UNCOVERED.iter().map(|(id, _)| (*id).to_owned()).collect();
    let mut problems: Vec<String> = contract.problems().to_vec();

    for (id, reason) in UNCOVERED {
        assert!(
            documented.contains(*id),
            "UNCOVERED lists `{id}` ({reason}), which schema/openapi.yaml does not document; \
             delete the entry"
        );
        assert!(
            !contract.covered().contains(*id),
            "UNCOVERED lists `{id}` as impossible to drive, but the script drives it; \
             delete the entry"
        );
    }

    for id in documented.difference(contract.covered()) {
        if exempt.contains(id) {
            continue;
        }
        problems.push(format!(
            "{id} is documented in schema/openapi.yaml but nothing in \
             tests/response_contract/script.rs calls it, so no response of its has ever \
             been checked. Add a case, or add it to UNCOVERED with a reason."
        ));
    }

    problems.sort();
    problems.dedup();
    assert!(
        problems.is_empty(),
        "\n{} response(s) do not match schema/openapi.yaml:\n\n{}\n",
        problems.len(),
        problems.join("\n")
    );
}
