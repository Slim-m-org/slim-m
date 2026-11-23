// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `slimm-supervisor` serves the socket; `gateway` and `chown-data` are what its own image
//! runs inside the sandbox (decision 0134).

use std::process::ExitCode;

use slimm_supervisor::{api, checks, config::Config, gateway, supervisor::Supervisor};

const DATA_OWNER: u32 = 65532;

fn main() -> ExitCode {
    let mode = std::env::args().nth(1).unwrap_or_default();
    match mode.as_str() {
        "--version" => {
            println!("slimm-supervisor {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        "chown-data" => match std::os::unix::fs::chown("/data", Some(DATA_OWNER), Some(DATA_OWNER))
        {
            Ok(()) => ExitCode::SUCCESS,
            Err(err) => fail(&format!("chown /data: {err}")),
        },
        "gateway" => run(async {
            let config = gateway::request::GatewayConfig::from_lookup(|k| std::env::var(k).ok())?;
            gateway::run(config).await.map_err(|e| e.to_string())
        }),
        "" | "serve" => run(serve()),
        other => fail(&format!(
            "unknown mode {other:?}; expected serve, gateway, chown-data or --version"
        )),
    }
}

async fn serve() -> Result<(), String> {
    tracing_subscriber::fmt()
        .json()
        .with_writer(std::io::stderr)
        .init();
    let config = Config::from_env()?;
    let instance =
        checks::instance_id(&config.state_dir).map_err(|e| format!("state directory: {e}"))?;
    let supervisor = Supervisor::new(config, instance);
    match supervisor.refresh_readiness().await {
        Ok(r) if r.ready() => tracing::info!(
            runtime = r.runtime,
            rootless = r.rootless,
            "runtime checks passed"
        ),
        Ok(r) => {
            return Err(format!(
                "the runtime cannot enforce the sandbox: {}",
                r.problems.join("; ")
            ));
        }
        Err(err) => return Err(err.to_string()),
    }
    api::serve(supervisor)
        .await
        .map_err(|e| format!("socket: {e}"))
}

fn run(fut: impl Future<Output = Result<(), String>>) -> ExitCode {
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(err) => return fail(&err.to_string()),
    };
    match runtime.block_on(fut) {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => fail(&err),
    }
}

fn fail(reason: &str) -> ExitCode {
    eprintln!("slimm-supervisor: {reason}");
    ExitCode::FAILURE
}
