// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Select menus on a bot's message, and the small form a bot opens in answer
//! to a press. See docs/decisions/0083-bot-token-reissue-select-menus-and-forms.md.

use super::*;

fn menu() -> Value {
    json!([{ "select": {
        "custom_id": "pick",
        "placeholder": "Choose a day",
        "options": [
            { "label": "Monday", "value": "mon" },
            { "label": "Tuesday", "value": "tue", "description": "second" },
            { "label": "Wednesday", "value": "wed" }
        ],
        "max_values": 2
    }}])
}

fn survey() -> Value {
    json!({
        "custom_id": "survey",
        "title": "Remind me",
        "fields": [
            { "custom_id": "what", "label": "What", "max_length": 40 },
            { "custom_id": "note", "label": "Note", "required": false, "multiline": true }
        ]
    })
}

async fn posted_menu(w: &World) -> Value {
    let (status, message) = post_with(w, &w.bot.1, menu()).await;
    assert_eq!(status, StatusCode::OK, "{message}");
    message
}

async fn choose(w: &World, token: &str, message: &Value, values: Value) -> (StatusCode, Value) {
    call(
        w,
        "POST",
        &format!(
            "/channels/{}/messages/{}/interactions",
            w.channel,
            message["id"].as_str().unwrap()
        ),
        token,
        Some(json!({ "id": Uuid::now_v7().to_string(), "custom_id": "pick", "values": values })),
    )
    .await
}

fn interaction_uri(w: &World, id: &str, verb: &str) -> String {
    format!("/channels/{}/interactions/{id}/{verb}", w.channel)
}

#[tokio::test]
async fn a_chosen_value_reaches_only_the_owning_bot_with_the_values() {
    let w = world().await;
    let sent = posted_menu(&w).await;
    assert_eq!(sent["components"][0]["select"]["custom_id"], "pick");
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let mut rival = connect(&w, addr, &w.other_bot.1).await;

    let (status, body) = choose(&w, &w.alice.1, &sent, json!(["mon", "wed"])).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let frame = frame_of_kind(&mut bot, "interaction.created")
        .await
        .expect("the owning bot hears the choice");
    assert_eq!(frame["kind"], "select");
    assert_eq!(frame["custom_id"], "pick");
    assert_eq!(frame["values"], json!(["mon", "wed"]));
    assert_eq!(frame["user_id"], w.alice.0.to_string());
    assert!(
        frame_of_kind(&mut rival, "interaction.created")
            .await
            .is_none()
    );
}

#[tokio::test]
async fn a_choice_the_menu_does_not_offer_is_refused() {
    let w = world().await;
    let sent = posted_menu(&w).await;
    for bad in [
        json!(["fri"]),
        json!([]),
        json!(["mon", "tue", "wed"]),
        json!(["mon", "mon"]),
    ] {
        let (status, _) = choose(&w, &w.alice.1, &sent, bad.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }
    let (status, _, _) = press(&w, &w.alice.1, &sent, "pick").await;
    assert_eq!(status, StatusCode::BAD_REQUEST, "a menu needs values");
}

#[tokio::test]
async fn a_button_takes_no_values_and_a_select_shares_its_row_with_nothing() {
    let w = world().await;
    let buttons = posted(&w).await;
    let (status, _) = call(
        &w,
        "POST",
        &format!(
            "/channels/{}/messages/{}/interactions",
            w.channel,
            buttons["id"].as_str().unwrap()
        ),
        &w.alice.1,
        Some(json!({ "id": Uuid::now_v7().to_string(), "custom_id": "hit", "values": ["x"] })),
    )
    .await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let mut mixed = menu();
    mixed[0]["buttons"] = json!([{ "label": "Hit", "style": "primary", "custom_id": "hit" }]);
    let (status, _) = post_with(&w, &w.bot.1, mixed).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let mut clash = menu();
    clash.as_array_mut().unwrap().push(json!({ "buttons": [
        { "label": "Pick", "style": "primary", "custom_id": "pick" }
    ]}));
    let (status, _) = post_with(&w, &w.bot.1, clash).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "ids are unique per message"
    );

    let mut too_many = menu();
    too_many[0]["select"]["max_values"] = json!(4);
    let (status, _) = post_with(&w, &w.bot.1, too_many).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "max_values past the options"
    );
}

#[tokio::test]
async fn a_bot_opens_a_form_for_the_presser_and_the_answers_reach_only_that_bot() {
    let w = world().await;
    let sent = posted(&w).await;
    let addr = serve(w.state.clone()).await;
    let mut bot = connect(&w, addr, &w.bot.1).await;
    let mut alice = connect(&w, addr, &w.alice.1).await;
    let mut bob = connect(&w, addr, &w.bob.1).await;

    let (_, _, press_id) = press(&w, &w.alice.1, &sent, "hit").await;
    let (status, _) = call(
        &w,
        "POST",
        &interaction_uri(&w, &press_id, "form"),
        &w.bot.1,
        Some(survey()),
    )
    .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert!(
        frame_of_kind(&mut alice, "interaction.answered")
            .await
            .is_some(),
        "opening the form answers the press"
    );
    let shown = frame_of_kind(&mut alice, "interaction.form")
        .await
        .expect("the presser is shown the form");
    assert_eq!(shown["form"]["title"], "Remind me");
    assert_eq!(shown["interaction_id"], press_id);
    assert!(
        frame_of_kind(&mut bob, "interaction.form").await.is_none(),
        "nobody else sees it"
    );

    let (status, _) = call(
        &w,
        "POST",
        &interaction_uri(&w, &press_id, "form"),
        &w.bot.1,
        Some(survey()),
    )
    .await;
    assert_eq!(status, StatusCode::CONFLICT, "one form per press");

    let submit_id = Uuid::now_v7().to_string();
    let (status, body) = call(
        &w,
        "POST",
        &interaction_uri(&w, &press_id, "submit"),
        &w.alice.1,
        Some(json!({ "id": submit_id, "fields": { "what": "water the plants" } })),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let frame = loop {
        let frame = frame_of_kind(&mut bot, "interaction.created")
            .await
            .expect("the bot hears the submission");
        if frame["kind"] == "form_submit" {
            break frame;
        }
    };
    assert_eq!(frame["interaction_id"], submit_id);
    assert_eq!(frame["custom_id"], "survey");
    assert_eq!(
        frame["fields"],
        json!({ "what": "water the plants", "note": "" })
    );
    assert_eq!(frame["user_id"], w.alice.0.to_string());
}

#[tokio::test]
async fn only_the_bot_that_was_pressed_can_open_a_form_and_only_a_valid_one() {
    let w = world().await;
    let sent = posted(&w).await;
    let (_, _, press_id) = press(&w, &w.alice.1, &sent, "hit").await;
    let uri = interaction_uri(&w, &press_id, "form");

    let (status, _) = call(&w, "POST", &uri, &w.other_bot.1, Some(survey())).await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "another bot's press is not its own"
    );
    let (status, _) = call(&w, "POST", &uri, &w.alice.1, Some(survey())).await;
    assert_eq!(status, StatusCode::NOT_FOUND, "a member opens no forms");

    let mut no_fields = survey();
    no_fields["fields"] = json!([]);
    let mut six = survey();
    six["fields"] = json!(
        (0..6)
            .map(|n| json!({ "custom_id": format!("f{n}"), "label": "F" }))
            .collect::<Vec<_>>()
    );
    let mut twice = survey();
    twice["fields"][1]["custom_id"] = json!("what");
    let mut long = survey();
    long["fields"][0]["max_length"] = json!(5000);
    for (why, bad) in [
        ("none", no_fields),
        ("six", six),
        ("duplicate", twice),
        ("long", long),
    ] {
        let (status, _) = call(&w, "POST", &uri, &w.bot.1, Some(bad)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}");
    }
    let (status, _) = call(&w, "POST", &uri, &w.bot.1, Some(survey())).await;
    assert_eq!(
        status,
        StatusCode::NO_CONTENT,
        "the refused forms left the press open"
    );
}

#[tokio::test]
async fn a_submission_must_fit_the_form_the_bot_opened() {
    let w = world().await;
    let sent = posted(&w).await;
    let (_, _, press_id) = press(&w, &w.alice.1, &sent, "hit").await;
    let submit = interaction_uri(&w, &press_id, "submit");
    let attempt = |token: String, fields: Value| {
        let (w, submit) = (&w, submit.clone());
        async move {
            call(
                w,
                "POST",
                &submit,
                &token,
                Some(json!({ "id": Uuid::now_v7().to_string(), "fields": fields })),
            )
            .await
            .0
        }
    };

    assert_eq!(
        attempt(w.alice.1.clone(), json!({ "what": "x" })).await,
        StatusCode::NOT_FOUND,
        "no form is open yet"
    );
    call(
        &w,
        "POST",
        &interaction_uri(&w, &press_id, "form"),
        &w.bot.1,
        Some(survey()),
    )
    .await;
    for (why, fields) in [
        ("missing required", json!({ "note": "n" })),
        ("unknown field", json!({ "what": "x", "extra": "y" })),
    ] {
        assert_eq!(
            attempt(w.alice.1.clone(), fields).await,
            StatusCode::BAD_REQUEST,
            "{why}"
        );
    }
    assert_eq!(
        attempt(w.bob.1.clone(), json!({ "what": "x" })).await,
        StatusCode::NOT_FOUND,
        "someone else's form"
    );
    assert_eq!(
        attempt(w.bot.1.clone(), json!({ "what": "x" })).await,
        StatusCode::FORBIDDEN,
        "a bot submits nothing"
    );
    assert_eq!(
        attempt(w.alice.1.clone(), json!({ "what": "ok", "note": "a\nb" })).await,
        StatusCode::OK
    );
}
