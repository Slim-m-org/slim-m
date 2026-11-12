// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Presses on a shared app surface are never lost, never forged and never
//! overwritten by a failure: each is applied in turn to the stored frame, a
//! press with no action redraws it, and a failed run answers only its presser.

use serde_json::Value;

use crate::support;
use support::board_world::{BoardWorld, install_board};
use support::tally_wasm::tally_wasm;
use support::wasm_fixtures::{canned_raw_wasm, fuel_burner_wasm};

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn simultaneous_presses_are_all_applied() {
    let world = BoardWorld::new("slimm-surface-presses", tally_wasm()).await;
    assert_eq!(world.press("").await.0, 200);

    let presses = (0..20).map(|_| world.press(r#"{"action":"tap"}"#));
    let answers = futures_util::future::join_all(presses).await;

    assert!(
        answers
            .iter()
            .all(|(status, body)| *status == 200 && body["ok"] == true)
    );
    assert_eq!(world.shared_state().await, "x".repeat(21));
}

#[tokio::test]
async fn a_press_without_an_action_redraws_instead_of_relaunching() {
    let world = BoardWorld::new("slimm-surface-redraw", tally_wasm()).await;
    world.press("").await;
    world.press(r#"{"action":"tap"}"#).await;
    for input in ["", "{}", r#"{"size":3}"#, "hello"] {
        world.press(input).await;
    }
    assert_eq!(world.shared_state().await, "x".repeat(2 + 4));
}

#[tokio::test]
async fn a_forged_state_without_an_action_never_reaches_the_module() {
    let world = BoardWorld::new("slimm-surface-forged", tally_wasm()).await;
    world.press("").await;
    world.press(r#"{"state":"forged"}"#).await;
    assert_eq!(world.shared_state().await, "xx");
}

#[tokio::test]
async fn a_host_failure_never_replaces_the_last_good_frame() {
    let world = BoardWorld::new("slimm-surface-hostfail", tally_wasm()).await;
    world.press("").await;
    world.press(r#"{"action":"tap"}"#).await;

    install_board(&world.store, fuel_burner_wasm()).await;
    let (_, failed) = world.press(r#"{"action":"tap"}"#).await;
    assert_eq!(failed["ok"], false);
    assert!(failed["error"].is_string());
    assert_eq!(world.shared_state().await, "xx");

    install_board(&world.store, tally_wasm()).await;
    world.press(r#"{"action":"tap"}"#).await;
    assert_eq!(world.shared_state().await, "xxx");
}

#[tokio::test]
async fn a_module_error_never_replaces_the_last_good_frame() {
    let world = BoardWorld::new("slimm-surface-moderr", tally_wasm()).await;
    world.press("").await;

    install_board(
        &world.store,
        canned_raw_wasm(br#"{"ok":false,"error":"nope"}"#),
    )
    .await;
    let (_, failed) = world.press(r#"{"action":"tap"}"#).await;
    assert_eq!(failed["ok"], false);
    assert_eq!(failed["error"], Value::from("nope"));
    let (ok, output) = world.shared_run().await;
    assert!(ok, "the failure replaced the frame: {output}");
}
