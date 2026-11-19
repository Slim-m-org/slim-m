// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The two sweeps: reading every GET for canaries, and asking every route twice to compare a
//! private id with one that names nothing.

use std::path::Path;

use axum::Router;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use serde_json::{Value, json};
use tower::ServiceExt;
use uuid::Uuid;

use super::world::{CANARIES, MODULE, Private};
use crate::support::app::{TestApp, builder};
use crate::support::openapi::{Method, extract_schema_routes};

/// Fewer operations than this means the schema extractor lost most of the file.
const MIN_OPERATIONS: usize = 150;

/// Never asked: these end the session the sweep is made with, or keep a limit of their own on disk.
const NEVER: &[&str] = &[
    "/auth/",
    "/devices",
    "/me",
    "/exports",
    "/space/uplink-test",
    "/ws",
];

fn schema_routes() -> Vec<(Method, String)> {
    let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
    let repo_root = manifest_dir.parent().and_then(Path::parent).unwrap();
    let routes = extract_schema_routes(repo_root);
    assert!(
        routes.len() >= MIN_OPERATIONS,
        "only {} operations",
        routes.len()
    );
    let asked = routes.into_iter().filter(|route| {
        let exact = route.path == "/me" || route.path == "/ws";
        let prefixed = NEVER
            .iter()
            .any(|never| *never != "/me" && route.path.starts_with(never));
        !exact && !prefixed
    });
    asked.map(|route| (route.method, route.path)).collect()
}

/// Every id worth trying for a path parameter of this name.
fn candidates(private: &Private, param: &str) -> Vec<String> {
    let lower = param.to_lowercase();
    if lower.contains("channel") {
        private.channels.clone()
    } else if lower.contains("message") {
        private.messages.clone()
    } else if lower.contains("category") {
        vec![private.category.clone()]
    } else if lower.contains("user") || lower.contains("sender") || lower.contains("bot") {
        private.users.clone()
    } else if lower.contains("module") {
        vec![MODULE.to_owned()]
    } else if lower.contains("webhook") {
        vec![private.webhook.clone()]
    } else {
        // Anything else still gets a private channel and message, in case a route takes one under another name.
        vec![private.channels[0].clone(), private.messages[0].clone()]
    }
}

/// Every concrete path the template makes from the private ids.
fn concrete_paths(private: &Private, template: &str) -> Vec<String> {
    let mut heads = vec![String::new()];
    let mut rest = template;
    while let Some(open) = rest.find('{') {
        let close = rest.find('}').expect("closed path parameter");
        let options = candidates(private, &rest[open + 1..close]);
        let lead = &rest[..open];
        heads = heads
            .iter()
            .flat_map(|head| options.iter().map(move |id| format!("{head}{lead}{id}")))
            .collect();
        rest = &rest[close + 1..];
    }
    heads
        .into_iter()
        .map(|head| format!("{head}{rest}"))
        .collect()
}

async fn send(
    router: &Router,
    method: &str,
    uri: &str,
    token: &str,
    body: &str,
) -> (StatusCode, String) {
    let mut request = Request::builder().method(method).uri(uri);
    request = request.header("authorization", format!("Bearer {token}"));
    let body = if matches!(method, "POST" | "PUT" | "PATCH") {
        request = request.header("content-type", "application/json");
        Body::from(body.to_owned())
    } else {
        Body::empty()
    };
    let response = router
        .clone()
        .oneshot(request.body(body).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = axum::body::to_bytes(response.into_body(), usize::MAX)
        .await
        .unwrap();
    (status, String::from_utf8_lossy(&bytes).into_owned())
}

/// Asks through routers of the same store, taking a new one whenever a rate limit runs out.
struct Asker<'a> {
    app: &'a TestApp,
    router: Router,
    token: &'a str,
}

impl<'a> Asker<'a> {
    fn new(app: &'a TestApp, token: &'a str) -> Self {
        let router = builder(app.store.clone()).router();
        Self { app, router, token }
    }

    async fn ask(&mut self, method: &str, uri: &str, body: &str) -> (StatusCode, String) {
        let mut answer = send(&self.router, method, uri, self.token, body).await;
        if answer.0 == StatusCode::TOO_MANY_REQUESTS {
            self.router = builder(self.app.store.clone()).router();
            answer = send(&self.router, method, uri, self.token, body).await;
        }
        assert_ne!(answer.0, StatusCode::TOO_MANY_REQUESTS, "{method} {uri}");
        assert_ne!(answer.0, StatusCode::UNAUTHORIZED, "{method} {uri}");
        answer
    }
}

/// The query strings a path is read with: none, and a search for each canary.
fn searches(template: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    if template.contains("search") || template == "/users" || template == "/members" {
        out.extend(CANARIES.iter().map(|word| format!("?q={word}")));
        out.push("?q=canary*".to_owned());
    }
    out
}

/// What `body` gives away to a caller who asked for `uri`.
fn given_away(private: &Private, uri: &str, body: &str) -> Vec<String> {
    let lower = body.to_lowercase();
    let told = |word: &str| lower.contains(word) && !uri.contains(word);
    let words = CANARIES.iter().filter(|word| told(word));
    let mut found: Vec<String> = words.map(|word| (*word).to_owned()).collect();
    let ids = private.ids.iter().filter(|id| told(id));
    found.extend(ids.map(|id| format!("id {id}")));
    found
}

/// Reads every GET as `token` with every private id in its path, and lists what each gave away.
pub async fn read_everything(app: &TestApp, private: &Private, token: &str) -> Vec<String> {
    let mut asker = Asker::new(app, token);
    let mut findings = Vec::new();
    let gets = schema_routes()
        .into_iter()
        .filter(|(method, _)| *method == Method::Get);
    for (_, template) in gets {
        for path in concrete_paths(private, &template) {
            for query in searches(&template) {
                let uri = format!("{path}{query}");
                let (status, body) = asker.ask("GET", &uri, "").await;
                let found = given_away(private, &uri, &body);
                if !found.is_empty() {
                    findings.push(format!("GET {template} -> {status}: {found:?}"));
                }
            }
        }
    }
    findings.sort();
    findings.dedup();
    findings
}

/// `text` with every private id swapped for an id that names nothing.
fn with_strangers(private: &Private, text: &str) -> String {
    let mut out = text.to_owned();
    for (index, id) in private.ids.iter().enumerate() {
        out = out.replace(id.as_str(), &format!("019e0000-0000-7000-8000-{index:012}"));
    }
    out
}

/// A body with a private id under every field name a route might read one from, and a value
/// under every other field a route requires, so its body parses and the ids in it are read.
fn loaded_body(private: &Private, template: &str, channel: &str, message: &str) -> Value {
    let parts = [
        json!({
            "id": Uuid::now_v7().to_string(),
            "content": "hello", "name": "hello", "label": "hello", "reason": "hello",
            "kind": "text", "emoji": "\u{1F44D}", "seq": 1, "allow": 0, "deny": 0,
            "muted": true, "deafened": true, "enabled": true, "preference": "nothing",
            "joins": "every", "streams": true, "position": 0, "limit": 1, "permissions": 0,
            "question": "hello", "options": ["one", "two"], "retention_days": 1,
        }),
        json!({
            "rules": "hello", "joins_paused": false, "resolution": "dismissed",
            "size": 1, "surface": "message_menu", "objects": [], "x": 0, "y": 0, "w": 1, "h": 1,
            "custom_id": "hello", "title": "hello", "command": "hello", "window_minutes": 1,
            "module_id": MODULE, "playing": true, "log": "hello", "images": [], "code": "hello",
            "duration_seconds": 60, "input": "hello", "subject_kind": "message",
        }),
        json!({
            "version": "0.1.0", "package": "hello", "$slim": "hello", "repo": "hello/hello",
            "scopes": [], "prefix": "!", "groups": [], "components": [], "item_id": "hello",
            "direct": true, "nickname": "hello", "timezone": "UTC", "until_ms": 0,
            "state": "hello", "platform": "hello", "include_content": true, "hook": "hello",
            "values": {}, "body": "hello", "position_ms": 0, "app_version": "1",
            "manifest": "hello", "days": [], "push_token": "hello", "off_hours_mode": "hello",
            "entry_id": "hello", "props": {}, "fields": [], "locked": false,
            "push_public_key": "hello", "sent_to_back": false,
        }),
        json!({
            "user_ids": private.users, "user_id": private.users[0], "target_id": private.users[0],
            "author_id": private.users[0], "target_user_id": private.users[0],
            "channel_id": channel, "to_channel_id": channel, "rules_channel_id": channel,
            "welcome_channel_id": channel, "channel_ids": [channel], "order": [channel],
            "category_id": private.category, "parent_id": private.category,
            "categories": [private.category], "ids": [channel, message, private.category],
        }),
        json!({
            "message_id": message, "message_ids": [message], "reply_to_id": message,
            "subject_id": message, "forwarded_from_id": message, "before": message, "after": message,
            "overwrites": [{"kind": "member", "id": private.users[1], "deny": 2}],
        }),
        its_own_fields(private, template, (channel, message)),
    ];
    let fields = parts
        .iter()
        .flat_map(|part| part.as_object().expect("an object").clone());
    Value::Object(fields.collect())
}

/// The fields one route reads in a shape another route's field of the same name cannot share.
fn its_own_fields(private: &Private, template: &str, (channel, message): (&str, &str)) -> Value {
    if template.ends_with("/call-audio/consent") {
        json!({"allow": true})
    } else if template.ends_with("/{messageId}/interactions") {
        json!({"values": []})
    } else if template.ends_with("/{interactionId}/submit") {
        json!({"fields": {}})
    } else if template == "/channels/order" {
        let group = json!({"category_id": private.category, "channel_ids": [channel]});
        json!({"order": null, "channel_ids": null, "categories": [group]})
    } else if template == "/reports" {
        json!({"channel_id": null, "author_id": null})
    } else if template.ends_with("/ephemeral-messages") {
        json!({"in_reply_to_id": message})
    } else {
        json!({})
    }
}

/// Routes whose body the sweep cannot write, each with why that hides nothing private.
const UNREAD_BODIES: &[(&str, &str)] = &[
    // Role ids only, and its refusal lists them in no fixed order.
    ("PATCH", "/roles/reorder"),
    // A theme or a package file: tokens, a manifest and an artifact, never a channel or a message.
    ("POST", "/space/themes"),
    ("POST", "/space/dock/packages/install"),
    ("POST", "/space/dock/packages/preview"),
];

/// Whether a refusal is the body or query failing to parse, before the route read any id in it.
fn never_read(text: &str) -> bool {
    const SHAPE: &[&str] = &[
        "missing field",
        "invalid type",
        "invalid value",
        "invalid length",
        "unknown variant",
        "unknown field",
        "did not match any variant",
        "expected",
    ];
    SHAPE.iter().any(|marker| text.contains(marker))
}

/// A success may differ by what it made, so only that it succeeded is compared.
fn comparable(private: &Private, (status, text): (StatusCode, String)) -> (StatusCode, String) {
    match status.is_success() {
        true => (StatusCode::OK, String::new()),
        false => (status, with_strangers(private, &text)),
    }
}

/// Asks every route twice as `token`, once naming private ids in its path, query and body and
/// once naming ids that name nothing, and lists every route whose two answers differ. `skip`
/// leaves a template out. `public` ids ride in the path too, so a body's private ids are
/// also judged on a route the caller may use.
pub async fn ask_twice(
    app: &TestApp,
    mut private: Private,
    token: &str,
    public: (String, String),
    skip: impl Fn(Method, &str) -> bool,
) -> Vec<String> {
    let pairs: Vec<(String, String)> = private
        .channels
        .iter()
        .cloned()
        .zip(private.messages.iter().cloned())
        .collect();
    private.channels.push(public.0);
    private.messages.push(public.1);
    let mut asker = Asker::new(app, token);
    let mut differences = Vec::new();
    for (method, template) in schema_routes() {
        if skip(method, &template) {
            continue;
        }
        let paths = concrete_paths(&private, &template);
        // One private pair per path, each in turn; a route with a single path meets them all.
        let per_path = if paths.len() == 1 { pairs.len() } else { 1 };
        for (turn, path) in paths.into_iter().enumerate() {
            for (channel, message) in pairs.iter().cycle().skip(turn).take(per_path) {
                let body = loaded_body(&private, &template, channel, message).to_string();
                let category = &private.category;
                let uri = format!(
                    "{path}?channel_id={channel}&message_id={message}&category_id={category}&q=hello&ids={channel}&days=0&after_seq=0&min_x=0&min_y=0&max_x=1&max_y=1&url=hello&offset=0&name=hello"
                );
                let stranger = (
                    with_strangers(&private, &uri),
                    with_strangers(&private, &body),
                );
                let method = method.as_str();
                // Either ask may uninstall or disarm it, which the next must not mistake for an answer.
                private.keep_the_module(app).await;
                let nothing =
                    comparable(&private, asker.ask(method, &stranger.0, &stranger.1).await);
                private.keep_the_module(app).await;
                let named = comparable(&private, asker.ask(method, &uri, &body).await);
                if named != nothing {
                    differences.push(format!(
                        "{method} {template}\n  a private id: {named:?}\n  no such id:   {nothing:?}"
                    ));
                }
                let excused = UNREAD_BODIES.contains(&(method, template.as_str()));
                if named.0 == StatusCode::BAD_REQUEST && never_read(&named.1) && !excused {
                    differences.push(format!(
                        "{method} {template} never read what it was sent: {}",
                        named.1
                    ));
                }
            }
        }
    }
    differences.sort();
    differences.dedup();
    differences
}
