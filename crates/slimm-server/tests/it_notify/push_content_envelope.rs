// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a device that asked for message content in its push actually gets,
//! and - the point of this file - what the relay gets while that happens.
//!
//! The relay is a shared, stateless forwarder: other people's notifications
//! pass through the same process, so "the relay cannot read a notification"
//! is the property that makes sharing one acceptable at all. Content rides
//! *inside* the sealed box, where it is exactly as opaque to the relay as the
//! channel id already was, and these tests assert that against the real
//! serialized `/v1/send` body captured off a real `reqwest` client, not
//! against the wire structs re-serialized against themselves.
//!
//! [`the_relay_never_sees_content_in_any_field_at_any_depth`] is the one to
//! keep working. It searches the whole serialized request body for the
//! message text, the sender's display name and the channel name, rather than
//! naming the fields it expects them to be absent from, so a field added
//! anywhere in the chain - a new debugging aid, a "title" convenience, a
//! future envelope field accidentally hoisted outside the seal - fails this
//! test rather than passing by not being on its list. It is the same
//! technique `message_ops`' `no_op_carries_an_actor_on_any_kind` uses for the
//! same reason.

use crate::push_envelope_harness;
use push_envelope_harness::*;

/// The property that makes a shared relay acceptable: nothing it is handed
/// carries the message, the sender, or the channel, in any field, at any
/// depth. See this file's own module docs for why it searches rather than
/// enumerating fields.
#[tokio::test]
async fn the_relay_never_sees_content_in_any_field_at_any_depth() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let _secret = register_push(&world.app, &recipient, "reader-token", true).await;

    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;

    let serialized = serde_json::to_string(&body).expect("the captured body re-serializes");
    for (what, sentinel) in [
        ("the message body", SENTINEL_BODY),
        ("the sender's display name", SENTINEL_SENDER),
        ("the channel name", SENTINEL_CHANNEL),
    ] {
        assert!(
            !serialized.contains(sentinel),
            "{what} reached the relay in cleartext, somewhere in: {serialized}"
        );
    }
}

/// Content is in the envelope, and only reachable with the device's own key.
#[tokio::test]
async fn an_opted_in_device_can_unseal_the_sender_channel_and_body() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &recipient, "reader-token", true).await;

    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;
    let envelope = unseal(entry_for(&body, "reader-token"), &secret);

    assert_eq!(envelope["body"], SENTINEL_BODY);
    assert_eq!(envelope["sender"], SENTINEL_SENDER);
    assert_eq!(envelope["channel"], SENTINEL_CHANNEL);
    // Untouched routing fields, so catching up over /sync works as before.
    assert_eq!(envelope["channel_id"], world.channel_id.to_string());
    assert_eq!(envelope["kind"], "message");
}

/// The whole defense against a hostile relay retaining and replaying a push:
/// `sent_at` is inside the sealed plaintext, not a routing field the relay
/// could see or hold constant, and it names when the server actually sealed
/// this envelope. Unsealing the real relay-bound payload with the device's
/// own key, the way [`unseal`] does, is what proves it is genuinely inside
/// the sealed box rather than only in the plaintext before it was sealed.
#[tokio::test]
async fn sent_at_is_inside_the_sealed_plaintext_and_recent() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &recipient, "reader-token", true).await;

    let before = epoch_ms();
    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;
    let after = epoch_ms();

    let envelope = unseal(entry_for(&body, "reader-token"), &secret);
    let sent_at = envelope["sent_at"]
        .as_i64()
        .expect("sent_at is present and a number");
    assert!(
        (before..=after).contains(&sent_at),
        "sent_at {sent_at} must fall within [{before}, {after}]"
    );
}

/// `sent_at` rides even when a device declined content, since a
/// content-free envelope is exactly as replayable as a preview-carrying one.
#[tokio::test]
async fn sent_at_is_present_even_when_a_device_declined_content() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &recipient, "reader-token", false).await;

    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;
    let envelope = unseal(entry_for(&body, "reader-token"), &secret);

    assert!(
        envelope["sent_at"].as_i64().is_some(),
        "a content-free envelope must still carry sent_at: {envelope}"
    );
}

/// A device that did not ask gets what it always got: no content field at
/// all, not a null or an empty string it would have to know to ignore.
///
/// This covers the whole-batch gate, not the per-device split: with nobody
/// opted in, `deliver` never resolves a preview in the first place, so no
/// name lookup even runs. Mutating `seal_for_message` to ignore
/// `include_content` leaves this test green for exactly that reason, which is
/// why [`one_devices_choice_never_reaches_another_devices_envelope`] exists
/// alongside it and is the one that actually fails on that mutation.
#[tokio::test]
async fn a_device_that_did_not_ask_gets_no_content_at_all() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &recipient, "reader-token", false).await;

    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;
    let envelope = unseal(entry_for(&body, "reader-token"), &secret);

    for field in ["sender", "channel", "body"] {
        assert!(
            envelope.get(field).is_none(),
            "an opted-out device's envelope must not carry {field}: {envelope}"
        );
    }
    assert_eq!(envelope["channel_id"], world.channel_id.to_string());
}

/// Opting in is per device, so one device asking for content must not put it
/// in a different device's envelope - including a different account's. Sealing
/// happens per target, and this is what fails if that ever becomes one shared
/// plaintext sealed to everybody.
#[tokio::test]
async fn one_devices_choice_never_reaches_another_devices_envelope() {
    let world = world().await;
    let store = world.store.clone();
    let opted_in = account(&store, "reader-in", "Reader In").await;
    let opted_out = account(&store, "reader-out", "Reader Out").await;
    let in_secret = register_push(&world.app, &opted_in, "in-token", true).await;
    let out_secret = register_push(&world.app, &opted_out, "out-token", false).await;

    send(&world, SENTINEL_BODY).await;
    let body = wait_for_capture(&world.captured).await;

    let opted_in_envelope = unseal(entry_for(&body, "in-token"), &in_secret);
    assert_eq!(opted_in_envelope["body"], SENTINEL_BODY);

    let opted_out_envelope = unseal(entry_for(&body, "out-token"), &out_secret);
    assert!(
        opted_out_envelope.get("body").is_none(),
        "the opted-out device's envelope carried the message: {opted_out_envelope}"
    );
}

/// A body past the preview cap is elided rather than sent whole, so one long
/// message cannot push the sealed payload past what the relay and APNs accept
/// - which would be a notification silently lost, not a visible error.
#[tokio::test]
async fn a_long_body_is_truncated_rather_than_sent_whole() {
    let world = world().await;
    let recipient = account(&world.store, "reader", "Reader").await;
    let secret = register_push(&world.app, &recipient, "reader-token", true).await;

    let long = "y".repeat(3_000);
    send(&world, &long).await;
    let body = wait_for_capture(&world.captured).await;
    let entry = entry_for(&body, "reader-token");

    // The relay's own maxPayloadBytes, itself APNs' whole-notification limit.
    let payload = entry["payload"].as_str().expect("payload is a string");
    assert!(
        payload.len() < 4_096,
        "the sealed payload must stay inside the relay's own limit, was {}",
        payload.len()
    );

    let envelope = unseal(entry, &secret);
    let preview = envelope["body"].as_str().expect("body is a string");
    assert!(
        preview.chars().count() < long.chars().count(),
        "a 3000-character message must not be sent whole"
    );
    assert!(
        preview.starts_with("yyy"),
        "the preview is the real message"
    );
}
