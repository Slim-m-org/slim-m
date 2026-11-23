// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A server shutting down while a module run is mid host call.

use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::runtime::Handle;

use super::tests_fixtures::{GENEROUS, host_call_wasm, sha256_hex};
use super::{CapabilitySurface, InMemoryKv, MessagePoster, ModuleHost, PostRefused};

/// Waits for the runtime to be torn down, then does what the sqlx-backed backends do: `block_on` a timer.
struct PosterOutlivingTheRuntime {
    handle: Handle,
    entered: mpsc::Sender<()>,
    runtime_gone: Mutex<mpsc::Receiver<()>>,
}

impl MessagePoster for PosterOutlivingTheRuntime {
    fn post(&self, _channel: Option<&str>, _content: &str) -> Result<String, PostRefused> {
        self.entered.send(()).unwrap();
        self.runtime_gone.lock().unwrap().recv().unwrap();
        self.handle
            .block_on(tokio::time::sleep(Duration::from_millis(1)));
        Ok("posted".to_owned())
    }
}

#[test]
fn a_runtime_dropped_mid_host_call_does_not_abort_the_process() {
    let runtime = tokio::runtime::Runtime::new().unwrap();
    let (entered, entered_rx) = mpsc::channel();
    let (gone, gone_rx) = mpsc::channel();
    let poster = Arc::new(PosterOutlivingTheRuntime {
        handle: runtime.handle().clone(),
        entered,
        runtime_gone: Mutex::new(gone_rx),
    });
    let surface = CapabilitySurface::enabled(
        vec!["message.post".to_owned()],
        "m",
        Arc::new(InMemoryKv::default()),
    )
    .with_poster(poster);
    let wasm = host_call_wasm(r#"{"capability":"message.post","content":"hi"}"#);
    let sha = sha256_hex(&wasm);
    runtime.spawn(async move {
        let _ = ModuleHost::run_with_capabilities(wasm, sha, GENEROUS, Vec::new(), surface).await;
    });
    entered_rx.recv_timeout(Duration::from_secs(10)).unwrap();

    // Dropping the runtime shuts its drivers down, then waits for the blocked run; release it once that has begun.
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        gone.send(()).unwrap();
    });
    drop(runtime);
}
