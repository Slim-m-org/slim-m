// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A call control that offers a choice, such as a stream's quality: the member
//! picks one and the bot hears which. See docs/decisions/0045-bot-contributed-ui.md.

use super::bot_ui::{listed, register, use_entry, voice_channel};
use super::*;

fn quality_control() -> Value {
    json!({
        "call_controls": [
            { "id": "pause", "label": "Pause", "icon": "pause" },
            {
                "id": "quality", "label": "Quality", "icon": "settings",
                "options": [
                    { "id": "low", "label": "Low 480p" },
                    { "id": "high", "label": "High 1080p" }
                ]
            }
        ]
    })
}

fn pick(entry: &str, option: Option<&str>) -> Value {
    let mut body = json!({ "surface": "call_control", "entry_id": entry });
    if let Some(option) = option {
        body["option_id"] = json!(option);
    }
    body
}

/// A voice channel with the member and the bot both on its call.
async fn on_a_call(w: &World) -> ChannelId {
    let channel = voice_channel(w).await;
    w.state
        .voice
        .record_heartbeat_reporting_new(w.alice.0, channel);
    w.state
        .voice
        .record_heartbeat_reporting_new(w.bot.0, channel);
    channel
}

#[tokio::test]
async fn a_control_lists_its_options_and_the_bot_hears_the_choice() {
    let w = world().await;
    assert_eq!(
        register(&w, &w.bot.1, quality_control()).await,
        StatusCode::NO_CONTENT
    );
    let channel = on_a_call(&w).await;

    let bots = listed(&w, channel, &w.alice.1).await;
    let controls = &bots[0]["call_controls"];
    assert!(
        controls[0].get("options").is_none(),
        "a plain button lists no options"
    );
    assert_eq!(controls[1]["icon"], "settings");
    assert_eq!(controls[1]["options"][1]["label"], "High 1080p");

    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let (status, id) = use_entry(&w, channel, &w.alice.1, pick("quality", Some("high"))).await;
    assert_eq!(status, StatusCode::OK);
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the bot hears it");
    assert_eq!(frame["interaction_id"], id);
    assert_eq!(frame["custom_id"], "quality");
    assert_eq!(frame["option_id"], "high");

    use_entry(&w, channel, &w.alice.1, pick("pause", None)).await;
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the bot hears it");
    assert!(
        frame.get("option_id").is_none(),
        "a plain button carries no choice"
    );
}

#[tokio::test]
async fn a_choice_must_be_one_the_control_offers() {
    let w = world().await;
    register(&w, &w.bot.1, quality_control()).await;
    let channel = on_a_call(&w).await;

    let (status, _) = use_entry(&w, channel, &w.alice.1, pick("quality", None)).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a choice control needs a choice"
    );
    let (status, _) = use_entry(&w, channel, &w.alice.1, pick("quality", Some("ultra"))).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "an option it does not offer");
    let (status, _) = use_entry(&w, channel, &w.alice.1, pick("pause", Some("low"))).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a plain button takes no choice"
    );
}

#[tokio::test]
async fn a_retried_use_with_another_choice_is_a_conflict() {
    let w = world().await;
    register(&w, &w.bot.1, quality_control()).await;
    let channel = on_a_call(&w).await;
    let id = Uuid::now_v7().to_string();
    let path = format!("/channels/{channel}/bot-ui/{}/interactions", w.bot.0);
    let mut body = pick("quality", Some("low"));
    body["id"] = json!(id);
    let (status, _) = call(&w, "POST", &path, &w.alice.1, Some(body.clone())).await;
    assert_eq!(status, StatusCode::OK);
    let (status, _) = call(&w, "POST", &path, &w.alice.1, Some(body.clone())).await;
    assert_eq!(status, StatusCode::OK, "the same use again");
    body["option_id"] = json!("high");
    let (status, _) = call(&w, "POST", &path, &w.alice.1, Some(body)).await;
    assert_eq!(status, StatusCode::CONFLICT);
}

#[tokio::test]
async fn a_bad_set_of_options_is_refused_whole() {
    let w = world().await;
    let one_option = json!({ "call_controls": [
        { "id": "q", "label": "Quality", "options": [{ "id": "low", "label": "Low" }] }
    ]});
    assert_eq!(
        register(&w, &w.bot.1, one_option).await,
        StatusCode::BAD_REQUEST
    );
    let on_a_menu = json!({ "message_menu": [
        { "id": "q", "label": "Quality", "options": [
            { "id": "a", "label": "A" }, { "id": "b", "label": "B" }
        ] }
    ]});
    assert_eq!(
        register(&w, &w.bot.1, on_a_menu).await,
        StatusCode::BAD_REQUEST
    );
}
