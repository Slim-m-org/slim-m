// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The control endpoint over a real WebSocket, with sessions faked.

use std::sync::Mutex;
use std::sync::atomic::AtomicBool;

use futures_util::{SinkExt, StreamExt};
use tokio_tungstenite::tungstenite::Message as Wire;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

use super::*;
use crate::stt::{Transcriber, Transcript};

const SECRET: &str = "0123456789abcdef0123456789abcdef";

struct Silent;
impl Transcriber for Silent {
    fn transcribe(&self, _: &[i16], _: Option<&str>) -> anyhow::Result<Transcript> {
        Ok(Transcript {
            text: String::new(),
            language: None,
        })
    }
    fn model(&self) -> String {
        "silent".into()
    }
}

/// Records what it was asked to launch and how each session was told to end.
#[derive(Default)]
struct Fake {
    launched: Mutex<Vec<(String, Vec<String>)>>,
    commands: Mutex<Vec<(String, SessionCommand)>>,
    panic_on_launch: AtomicBool,
}

impl Launcher for Arc<Fake> {
    fn launch(&self, launch: Launch) -> Running {
        assert!(
            !self.panic_on_launch.load(Ordering::Acquire),
            "the launcher was told to fail"
        );
        let mut include: Vec<String> = launch.include.iter().cloned().collect();
        include.sort();
        self.launched
            .lock()
            .unwrap()
            .push((launch.session.clone(), include));
        let (commands, mut feed) = unbounded_channel();
        let fake = Arc::clone(self);
        let (session, reports) = (launch.session, launch.reports);
        let task = tokio::spawn(async move {
            let _ = reports.send(Report::Started {
                session: session.clone(),
            });
            while let Some(command) = feed.recv().await {
                let stop = command == SessionCommand::Stop;
                fake.commands
                    .lock()
                    .unwrap()
                    .push((session.clone(), command));
                if stop {
                    return;
                }
            }
        });
        Running { commands, task }
    }
}

async fn start(max_sessions: u32) -> (String, Arc<Fake>) {
    start_with(max_sessions, SILENCE_LIMIT).await
}

async fn start_with(max_sessions: u32, silence: Duration) -> (String, Arc<Fake>) {
    let config = Arc::new(Config {
        listen: "127.0.0.1:0".parse().unwrap(),
        secret: SECRET.into(),
        model: "m".into(),
        language: None,
        threads: 1,
        max_sessions,
    });
    let fake = Arc::new(Fake::default());
    let pool = Arc::new(Pool::new(Arc::new(Silent), 1));
    let router = Control::new(config, pool, Arc::new(Arc::clone(&fake)))
        .with_silence_limit(silence)
        .router();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(async move { axum::serve(listener, router).await });
    (format!("ws://{addr}/v1/control"), fake)
}

type Client =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect(url: &str, secret: &str) -> Result<Client, tokio_tungstenite::tungstenite::Error> {
    let mut request = url.into_client_request().unwrap();
    request
        .headers_mut()
        .insert("authorization", format!("Bearer {secret}").parse().unwrap());
    tokio_tungstenite::connect_async(request)
        .await
        .map(|(s, _)| s)
}

async fn next_json(client: &mut Client) -> serde_json::Value {
    loop {
        let frame = tokio::time::timeout(Duration::from_secs(5), client.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        if let Wire::Text(text) = frame {
            return serde_json::from_str(text.as_str()).unwrap();
        }
    }
}

fn start_frame(session: &str, include: &[&str]) -> Wire {
    Wire::text(
        serde_json::json!({"v":1,"type":"start","session":session,"livekit_url":"ws://lk",
            "token":"t","include":include,"language":null})
        .to_string(),
    )
}

#[tokio::test]
async fn a_wrong_or_missing_secret_is_refused() {
    let (url, _) = start(2).await;
    assert!(
        connect(&url, "not-the-secret-not-the-secret-xx")
            .await
            .is_err()
    );
    assert!(tokio_tungstenite::connect_async(&url).await.is_err());
}

#[tokio::test]
async fn the_right_secret_gets_ready_with_the_model_and_limit() {
    let (url, _) = start(3).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    let ready = next_json(&mut client).await;
    assert_eq!(ready["type"], "ready");
    assert_eq!(ready["v"], 1);
    assert_eq!(ready["model"], "silent");
    assert_eq!(ready["max_sessions"], 3);
}

#[tokio::test]
async fn a_second_control_connection_is_refused_while_one_is_open() {
    let (url, _) = start(2).await;
    let _first = connect(&url, SECRET).await.unwrap();
    assert!(connect(&url, SECRET).await.is_err());
}

#[tokio::test]
async fn start_include_and_stop_reach_the_session() {
    let (url, fake) = start(2).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    next_json(&mut client).await;
    client.send(start_frame("s1", &["u2", "u1"])).await.unwrap();
    let started = next_json(&mut client).await;
    assert_eq!(
        (started["type"].as_str(), started["session"].as_str()),
        (Some("started"), Some("s1"))
    );
    client
        .send(Wire::text(
            r#"{"v":1,"type":"include","session":"s1","include":["u1"]}"#,
        ))
        .await
        .unwrap();
    client
        .send(Wire::text(r#"{"v":1,"type":"stop","session":"s1"}"#))
        .await
        .unwrap();
    for _ in 0..100 {
        if fake.commands.lock().unwrap().len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(
        *fake.launched.lock().unwrap(),
        vec![("s1".to_owned(), vec!["u1".to_owned(), "u2".to_owned()])]
    );
    let commands = fake.commands.lock().unwrap();
    assert_eq!(
        commands[0].1,
        SessionCommand::Include(["u1".to_owned()].into())
    );
    assert_eq!(commands[1].1, SessionCommand::Stop);
}

#[tokio::test]
async fn past_max_sessions_a_start_is_ended_as_overload_without_launching() {
    let (url, fake) = start(1).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    next_json(&mut client).await;
    client.send(start_frame("s1", &["u1"])).await.unwrap();
    next_json(&mut client).await;
    client.send(start_frame("s2", &["u1"])).await.unwrap();
    let ended = next_json(&mut client).await;
    assert_eq!(ended["type"], "ended");
    assert_eq!(ended["session"], "s2");
    assert_eq!(ended["reason"], "overload");
    assert_eq!(fake.launched.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn closing_the_connection_stops_every_session() {
    let (url, fake) = start(2).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    next_json(&mut client).await;
    client.send(start_frame("s1", &["u1"])).await.unwrap();
    client.send(start_frame("s2", &["u1"])).await.unwrap();
    next_json(&mut client).await;
    next_json(&mut client).await;
    drop(client);
    for _ in 0..100 {
        if fake.commands.lock().unwrap().len() == 2 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let commands = fake.commands.lock().unwrap();
    assert_eq!(commands.len(), 2);
    assert!(commands.iter().all(|(_, c)| *c == SessionCommand::Stop));
}

#[tokio::test]
async fn a_quiet_server_counts_as_a_lost_connection() {
    let (url, fake) = start_with(2, Duration::from_millis(300)).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    next_json(&mut client).await;
    client.send(start_frame("s1", &["u1"])).await.unwrap();
    next_json(&mut client).await;
    for _ in 0..100 {
        if !fake.commands.lock().unwrap().is_empty() {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(fake.commands.lock().unwrap()[0].1, SessionCommand::Stop);
    drop(client);
}

#[test]
fn secrets_compare_whole() {
    assert!(same_secret("abc", "abc"));
    assert!(!same_secret("abc", "abd"));
    assert!(!same_secret("abc", "abcd"));
    assert!(!same_secret("", "abc"));
}

#[tokio::test]
async fn a_launcher_that_panics_does_not_lock_the_server_out() {
    let (url, fake) = start(2).await;
    let mut client = connect(&url, SECRET).await.unwrap();
    next_json(&mut client).await;
    fake.panic_on_launch.store(true, Ordering::Release);
    client.send(start_frame("s1", &["u1"])).await.unwrap();
    drop(client);
    fake.panic_on_launch.store(false, Ordering::Release);
    let mut reconnected = false;
    for _ in 0..100 {
        if connect(&url, SECRET).await.is_ok() {
            reconnected = true;
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert!(reconnected, "the control slot stayed taken after a panic");
}

#[test]
fn a_slot_whose_upgrade_never_runs_is_released() {
    let flag = Arc::new(AtomicBool::new(false));
    let slot = ControlSlot::take(&flag).expect("free");
    assert!(ControlSlot::take(&flag).is_none());
    let never_polled = async move {
        let _slot = slot;
    };
    drop(never_polled);
    assert!(ControlSlot::take(&flag).is_some());
}
