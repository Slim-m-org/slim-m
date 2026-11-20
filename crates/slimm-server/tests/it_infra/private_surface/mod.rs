// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Nothing private reaches someone outside it, through any documented route.
//!
//! One deployment holds a private category and channel, a thread, a private
//! voice channel, a webhook, a file, a direct message and a group, each with a
//! canary word, and a module armed for the voice channel ([`world`]). Two
//! sweeps then walk `schema/openapi.yaml`, so a new route is asked the day it
//! is documented ([`probe`]):
//!
//! - every GET, with every private id in its path, may hand back neither a
//!   canary nor a private id the request did not name;
//! - every route, asked once naming private ids (path, query and body) and
//!   once naming ids that name nothing, must answer both alike. A difference
//!   means the route acted on, or admitted to, something its caller cannot see.
//!
//! They run for a plain member, for one who was in the channel and lost it,
//! for a bot, and for a manager holding every permission but ADMINISTRATOR:
//! decision 0011's rule is that a channel's permissions stop at the channel,
//! whatever the caller holds deployment-wide.
//!
//! Asked is not covered: a path id the sweep has no value for, a refusal the
//! handler writes before reading an id, and data the world does not hold all
//! pass unseen. docs/internals.md, "What the sweep cannot see", lists them.

mod probe;
mod world;

use serde_json::json;
use slimm_server::permissions::Permissions;

use crate::support;
use probe::{ask_twice, read_everything};
use support::app::TestApp;
use support::openapi::Method;
use world::{CANARIES, build, ok, say};

/// A public channel and a message in it, for [`ask_twice`].
async fn public(app: &TestApp) -> (String, String) {
    let general = app.general_channel().await;
    let message = say(app, &app.admin.token, &general, "hello").await;
    (general, message)
}

/// Gives `member` every permission but ADMINISTRATOR.
async fn make_a_manager(app: &TestApp) {
    let all = Permissions::ALL.remove(Permissions::ADMINISTRATOR);
    let role = app.create_role("managers", all.bits()).await;
    let grant = format!("/members/{}/roles/{role}", app.member.id);
    ok(app, "PUT", &grant, &app.admin.token, json!({})).await;
}

/// A `/members/` route acts on a person, never on anything private.
fn a_manager_may(_: Method, template: &str) -> bool {
    template.starts_with("/members/")
}

#[tokio::test]
async fn no_get_hands_a_member_anything_private() {
    let app = TestApp::start("slimm-private-surface-read").await;
    let private = build(&app, None).await;
    let found = read_everything(&app, &private, &app.member.token).await;
    assert!(found.is_empty(), "{found:#?}");
}

#[tokio::test]
async fn no_get_hands_back_what_a_member_could_see_before_they_lost_the_channel() {
    let app = TestApp::start("slimm-private-surface-former").await;
    let private = build(&app, Some(&app.member)).await;
    let found = read_everything(&app, &private, &app.member.token).await;
    assert!(found.is_empty(), "{found:#?}");
}

#[tokio::test]
async fn the_read_sweep_finds_every_canary_for_someone_who_may_read_them() {
    let app = TestApp::start("slimm-private-surface-control").await;
    let private = build(&app, None).await;
    let found = read_everything(&app, &private, &app.admin.token)
        .await
        .join("\n");
    let missed: Vec<_> = CANARIES.iter().filter(|w| !found.contains(**w)).collect();
    assert!(missed.is_empty(), "the admin's sweep never met {missed:?}");
}

#[tokio::test]
async fn a_private_id_answers_a_member_exactly_as_an_id_that_names_nothing() {
    let app = TestApp::start("slimm-private-surface-member").await;
    let private = build(&app, None).await;
    let token = &app.member.token;
    let differ = ask_twice(&app, private, token, public(&app).await, |_, _| false).await;
    assert!(differ.is_empty(), "{}", differ.join("\n"));
}

#[tokio::test]
async fn a_private_id_answers_a_bot_exactly_as_an_id_that_names_nothing() {
    let app = TestApp::start("slimm-private-surface-bot").await;
    let private = build(&app, None).await;
    let robot = json!({"username": "robot", "permissions": 0});
    let bot = ok(&app, "POST", "/bots", &app.admin.token, robot).await;
    let token = bot["token"].as_str().expect("a bot token");
    let differ = ask_twice(&app, private, token, public(&app).await, |_, _| false).await;
    assert!(differ.is_empty(), "{}", differ.join("\n"));
}

#[tokio::test]
async fn a_private_id_answers_a_manager_who_cannot_see_it_as_an_id_that_names_nothing() {
    let app = TestApp::start("slimm-private-surface-manager").await;
    let private = build(&app, None).await;
    make_a_manager(&app).await;
    let token = &app.member.token;
    let differ = ask_twice(&app, private, token, public(&app).await, a_manager_may).await;
    assert!(differ.is_empty(), "{}", differ.join("\n"));
}

#[tokio::test]
async fn no_get_hands_a_manager_what_is_in_a_channel_they_cannot_see() {
    let app = TestApp::start("slimm-private-surface-manager-read").await;
    let private = build(&app, None).await;
    make_a_manager(&app).await;
    let found = read_everything(&app, &private, &app.member.token).await;
    // The audit log names what was changed by id.
    let by_design = |line: &&String| !line.starts_with("GET /space/audit-log ->");
    let found: Vec<_> = found.iter().filter(by_design).collect();
    assert!(found.is_empty(), "{found:#?}");
}

#[tokio::test]
async fn the_ask_twice_sweep_tells_ids_apart_for_someone_who_may_see_them() {
    let app = TestApp::start("slimm-private-surface-ask-control").await;
    let private = build(&app, None).await;
    let token = &app.admin.token;
    // Only reads, so the admin does not delete the world the sweep is asking about.
    let reads_only = |method, _: &str| method != Method::Get;
    let differ = ask_twice(&app, private, token, public(&app).await, reads_only).await;
    for route in [
        "GET /channels/{channelId}/messages\n",
        "GET /channels/{channelId}/pins\n",
    ] {
        assert!(
            differ.iter().any(|d| d.starts_with(route)),
            "the admin's sweep never told {route:?} apart from a missing id:\n{}",
            differ.join("\n")
        );
    }
}
