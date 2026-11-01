// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a message send costs with no hook installed, with an unrelated module
//! installed, and with an allow-everything interceptor. A measurement, not a
//! gate: run it with `--ignored --nocapture` (decision 0100).

use std::time::{Duration, Instant};

use serde_json::json;

mod support;
use support::module_hooks_world::{HookModule, answering, interceptor, permission_hook};
use support::module_world::{Install, World, world};
use support::wasm_fixtures::canned_ok_wasm;

const SENDS: usize = 100;
/// Keeps under the write rate limit, which is not what is being measured.
const GAP: Duration = Duration::from_millis(230);

async fn timed_sends(w: &World, channel: slimm_server::ids::ChannelId) -> Vec<Duration> {
    let mut times = Vec::with_capacity(SENDS);
    for n in 0..SENDS {
        let started = Instant::now();
        let (status, body) = w.say(channel, &format!("message {n}")).await;
        assert_eq!(status, 200, "{body}");
        times.push(started.elapsed());
        tokio::time::sleep(GAP).await;
    }
    times.sort();
    times
}

fn report(label: &str, times: &[Duration]) {
    let mean: Duration = times.iter().sum::<Duration>() / u32::try_from(times.len()).unwrap();
    println!(
        "{label:<46} p50 {:>8.2?}  p95 {:>8.2?}  mean {:>8.2?}",
        times[times.len() / 2],
        times[times.len() * 95 / 100],
        mean
    );
}

#[tokio::test(flavor = "multi_thread")]
/// Prints the numbers; asserts only that every send succeeds.
#[ignore = "a measurement; run with --ignored --nocapture"]
async fn send_latency_with_and_without_hooks() {
    let w = world("slimm-hooks-latency").await;
    let channel = w.store.create_channel("general", "text").await.unwrap().id;
    timed_sends(&w, channel).await;

    report("no module installed", &timed_sends(&w, channel).await);

    w.install(Install {
        id: "bystander",
        wasm: canned_ok_wasm("hi"),
        declared: &[],
        approved_host: &[],
    })
    .await;
    report(
        "a module with no hooks installed",
        &timed_sends(&w, channel).await,
    );

    let idle = {
        let started = Instant::now();
        for _ in 0..1_000_000 {
            assert!(w.state.dock.hooks().is_idle(&w.store).await);
        }
        started.elapsed() / 1_000_000
    };
    println!("{:<46} {idle:?} per call", "idle registry check");

    w.install_hook_module(HookModule {
        id: "allow-all",
        wasm: answering(&json!({ "action": "allow" })),
        hooks: vec![interceptor("message.pre_send", "reject", &["content"])],
    })
    .await;
    report(
        "one reject interceptor installed",
        &timed_sends(&w, channel).await,
    );

    w.install_hook_module(HookModule {
        id: "gate",
        wasm: answering(&json!({ "allow": true })),
        hooks: vec![permission_hook("message.send")],
    })
    .await;
    report(
        "interceptor and permission hook installed",
        &timed_sends(&w, channel).await,
    );
}
