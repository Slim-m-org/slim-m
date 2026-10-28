// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Voice kick, the actor-versus-target half: `voice.rs`'s `kick` handler is
//! the one KICK_MEMBERS consumer with no level check before this pass, and
//! it needs its own per-channel escalation guard rather than the
//! deployment-wide one `members.rs` already carries. Split into its own file
//! because `tests/voice.rs` was already past the file-size budget.

use axum::Router;
use axum::http::StatusCode;
use slimm_server::permissions::Permissions;
use slimm_server::store::Store;
use slimm_server::voice::VoiceService;
use tower::ServiceExt;

mod support;

use support::app::request_bare as request;

fn app(store: Store, voice: VoiceService) -> Router {
    support::app::builder(store).voice(voice).router()
}

/// A loopback address nothing can be listening on: connecting to it fails
/// fast and locally, unlike a real unreachable hostname which needs a DNS
/// lookup first. `tests/voice_roster.rs` uses the same trick for the same
/// reason, and its own comment records why a privileged port beats a freed
/// ephemeral one (a race with whichever mock service this suite starts next).
fn unreachable_voice() -> VoiceService {
    VoiceService::for_test(
        "http://127.0.0.1:1",
        "APItestkey",
        "a-test-secret-of-at-least-32-characters",
    )
}

/// A moderator whose KICK_MEMBERS comes only from a channel overwrite, not
/// from a deployment-wide role, cannot use it to eject someone above their
/// level. The per-channel grant this route reads is exactly as bounded as
/// the deployment-wide one `members.rs` already guards, and comparing
/// against the wrong scope (the caller's deployment-wide permissions rather
/// than this channel's) is exactly the mistake that would have missed it.
#[tokio::test]
async fn kicking_above_your_level_via_a_channel_overwrite_is_refused() {
    let (store, _guard) = support::new_store("slimm-voice-kick-escalation-test").await;
    // alice registers first and claims the deployment as its administrator.
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.create_channel("mod-lounge", "voice").await.unwrap();

    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let bob_token = store
        .open_session(bob.id, "cli")
        .await
        .unwrap()
        .access_token;
    store
        .set_member_overwrite(
            channel.id,
            bob.id,
            Permissions::VIEW_CHANNEL.union(Permissions::KICK_MEMBERS),
            Permissions::NONE,
        )
        .await
        .unwrap();

    let app = app(store.clone(), unreachable_voice());
    let response = app
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, alice.id
            ),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "a channel overwrite must not out-rank a deployment administrator"
    );
}

/// Positive control: an administrator kicking a member with no special
/// rights is not caught by the guard above. The SFU is deliberately
/// unreachable here, so the outcome asserted is the authorization decision
/// (past `escalation_guard`) rather than a success no test fixture can
/// produce; `voice_roster.rs` reads the same 503 the same way.
#[tokio::test]
async fn an_administrator_can_still_kick_a_lower_privileged_participant() {
    let (store, _guard) = support::new_store("slimm-voice-kick-escalation-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let alice_token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;
    let channel = store.create_channel("general", "voice").await.unwrap();
    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();

    let app = app(store.clone(), unreachable_voice());
    let response = app
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, bob.id
            ),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::SERVICE_UNAVAILABLE,
        "authorized and past the guard; the unreachable SFU is what answers next"
    );
}

/// Control: kicking yourself still passes the guard, proving
/// `members.rs`'s self-refusal was not imported where it does not belong -
/// a self-kick is harmless, unlike self-removal from the Space.
#[tokio::test]
async fn kicking_yourself_is_not_refused_by_the_escalation_guard() {
    let (store, _guard) = support::new_store("slimm-voice-kick-escalation-test").await;
    store
        .create_role(
            "everyone",
            Permissions::VIEW_CHANNEL
                .union(Permissions::CONNECT)
                .union(Permissions::KICK_MEMBERS),
            true,
        )
        .await
        .unwrap();
    let channel = store.create_channel("general", "text").await.unwrap();
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    // A no-op: "everyone" above already claimed the deployment.
    store.bootstrap_deployment(alice.id).await.unwrap();
    let token = store
        .open_session(alice.id, "cli")
        .await
        .unwrap()
        .access_token;

    let app = app(store.clone(), unreachable_voice());
    let response = app
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, alice.id
            ),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::SERVICE_UNAVAILABLE,
        "authorized and past the guard; the unreachable SFU is what answers next"
    );
}

/// A timeout on the target must not become the lever that makes them kickable.
///
/// `escalation_guard` reads the target's *granted* channel permissions, never
/// their effective ones, so a timeout already stripping a senior participant's
/// grant cannot be what drops them into a junior moderator's reach. This is
/// the voice-kick sibling of the property `member_timeout.rs` pins for member
/// moderation ("else a timeout is what makes somebody re-timeout-able") - the
/// same subtraction, the same trap, a different handler. carol out-ranks bob
/// only by SPEAK, which `TIMEOUT_DENY` removes, so reading effective
/// permissions here would let bob eject a carol he can never eject otherwise.
#[tokio::test]
async fn a_timeout_on_the_target_is_not_a_lever_to_kick_them() {
    let (store, _guard) = support::new_store("slimm-voice-kick-escalation-test").await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.create_channel("mod-lounge", "voice").await.unwrap();

    let bob = store
        .create_account("bob", "bob", "not-a-real-hash")
        .await
        .unwrap();
    let bob_token = store
        .open_session(bob.id, "cli")
        .await
        .unwrap()
        .access_token;
    store
        .set_member_overwrite(
            channel.id,
            bob.id,
            Permissions::VIEW_CHANNEL.union(Permissions::KICK_MEMBERS),
            // Deny SPEAK: the default everyone role grants it, and this test turns on bob lacking exactly the bit carol keeps.
            Permissions::SPEAK,
        )
        .await
        .unwrap();

    let carol = store
        .create_account("carol", "carol", "not-a-real-hash")
        .await
        .unwrap();
    store
        .set_member_overwrite(
            channel.id,
            carol.id,
            Permissions::VIEW_CHANNEL
                .union(Permissions::KICK_MEMBERS)
                .union(Permissions::SPEAK),
            Permissions::NONE,
        )
        .await
        .unwrap();

    // Asserted so the test cannot pass vacuously: carol out-ranks bob only by SPEAK, a bit a timeout takes away.
    let bob_granted = store
        .granted_permissions_in_channel(bob.id, channel.id)
        .await
        .unwrap();
    assert!(!bob_granted.contains(Permissions::SPEAK));
    assert!(
        store
            .granted_permissions_in_channel(carol.id, channel.id)
            .await
            .unwrap()
            .contains(Permissions::SPEAK)
    );

    // A far-future timeout on carol collapses her effective SPEAK to nothing.
    const YEAR_3000_MS: i64 = 32_503_680_000_000;
    store
        .set_member_timeout(carol.id, YEAR_3000_MS, Some("cool off"), alice.id)
        .await
        .unwrap();
    assert!(
        !store
            .permissions_in_channel(carol.id, channel.id)
            .await
            .unwrap()
            .contains(Permissions::SPEAK),
        "the timeout must actually be in force, or this test proves nothing",
    );
    // Her granted SPEAK, the side the guard compares against, is untouched.
    assert!(
        store
            .granted_permissions_in_channel(carol.id, channel.id)
            .await
            .unwrap()
            .contains(Permissions::SPEAK)
    );

    let app = app(store.clone(), unreachable_voice());
    let response = app
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, carol.id
            ),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        response.status(),
        StatusCode::FORBIDDEN,
        "a timed-out senior must stay out of a junior moderator's reach; a 503 \
         would mean the guard compared effective permissions and let it through"
    );
}

/// Two members who both hold KICK_MEMBERS in a channel, as one call's
/// moderators of a channel overwrite. Returns the store, its guard, the
/// channel and the two accounts with bob's token.
async fn two_kickers(
    name: &str,
) -> (
    Store,
    support::TestDbGuard,
    slimm_server::store::Channel,
    slimm_server::ids::UserId,
    String,
    slimm_server::ids::UserId,
) {
    let (store, guard) = support::new_store(name).await;
    let alice = store
        .create_account("alice", "alice", "not-a-real-hash")
        .await
        .unwrap();
    store.bootstrap_deployment(alice.id).await.unwrap();
    let channel = store.create_channel("lounge", "voice").await.unwrap();
    let mut ids = Vec::new();
    for who in ["bob", "carol"] {
        let account = store
            .create_account(who, who, "not-a-real-hash")
            .await
            .unwrap();
        store
            .set_member_overwrite(
                channel.id,
                account.id,
                Permissions::VIEW_CHANNEL.union(Permissions::KICK_MEMBERS),
                Permissions::NONE,
            )
            .await
            .unwrap();
        ids.push(account.id);
    }
    let bob_token = store
        .open_session(ids[0], "cli")
        .await
        .unwrap()
        .access_token;
    (store, guard, channel, ids[0], bob_token, ids[1])
}

async fn kick_status(
    store: &Store,
    channel: &slimm_server::store::Channel,
    target: slimm_server::ids::UserId,
    token: &str,
) -> (StatusCode, String) {
    let response = app(store.clone(), unreachable_voice())
        .oneshot(request(
            "POST",
            &format!(
                "/channels/{}/voice/participants/{}/kick",
                channel.id, target
            ),
            Some(token),
        ))
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&bytes).into_owned())
}

/// Equal rank in a call: both hold KICK_MEMBERS in the channel and neither
/// holds a role, so neither can kick the other (owner decision 2026-10-28).
#[tokio::test]
async fn an_equal_rank_peer_cannot_be_voice_kicked() {
    let (store, _guard, channel, _bob, bob_token, carol) =
        two_kickers("slimm-voice-kick-rank-test").await;
    let (status, body) = kick_status(&store, &channel, carol, &bob_token).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert!(
        body.contains("equal rank"),
        "the client explains it: {body}"
    );
}

/// A higher role outranks: bob's role sits above carol's, so the kick gets
/// past the guards (the unreachable SFU answers next), and not the reverse.
#[tokio::test]
async fn a_higher_role_can_voice_kick_a_lower_one_and_not_the_reverse() {
    let (store, _guard, channel, bob, bob_token, carol) =
        two_kickers("slimm-voice-kick-rank-test").await;
    let mods = store
        .create_role("mods", Permissions::NONE, false)
        .await
        .unwrap();
    let regulars = store
        .create_role("regulars", Permissions::NONE, false)
        .await
        .unwrap();
    let mut order = vec![mods, regulars];
    for role in store.list_roles().await.unwrap() {
        if !role.is_everyone && !order.contains(&role.id) {
            order.push(role.id);
        }
    }
    store.reorder_roles(&order).await.unwrap();
    store.assign_role(bob, mods).await.unwrap();
    store.assign_role(carol, regulars).await.unwrap();

    let (status, _) = kick_status(&store, &channel, carol, &bob_token).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE, "past every guard");

    let carol_token = store.open_session(carol, "cli").await.unwrap().access_token;
    let (status, _) = kick_status(&store, &channel, bob, &carol_token).await;
    assert_eq!(status, StatusCode::FORBIDDEN, "a lower role cannot kick up");
}
