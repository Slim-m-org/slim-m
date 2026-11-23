// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! A real-Docker stage for one test: a local registry holding the probe connector, the
//! supervisor's own image built from this test binary, an egress network and a stand-in
//! server. Everything carries `org.slim-m.test=<run>` and is removed on drop.

use std::path::Path;
use std::process::Command;

use super::{Client, TestDir, config, socket_for, start};

pub const TEST_LABEL: &str = "org.slim-m.test";

pub struct Stage {
    pub run: String,
    pub dir: TestDir,
    pub registry_prefix: String,
    pub probe_image: String,
    pub own_image: String,
    pub egress_network: String,
    pub server_name: String,
    pub instances: Vec<String>,
    pub handles: Vec<std::sync::Arc<slimm_supervisor::supervisor::Supervisor>>,
}

pub fn docker(args: &[&str]) -> String {
    let out = Command::new("docker")
        .args(args)
        .output()
        .expect("docker runs");
    assert!(
        out.status.success(),
        "docker {args:?}: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

fn docker_ok(args: &[&str]) -> bool {
    Command::new("docker")
        .args(args)
        .output()
        .is_ok_and(|o| o.status.success())
}

impl Stage {
    pub fn new() -> Self {
        let run = uuid::Uuid::now_v7().simple().to_string()[16..].to_owned();
        let label = format!("{TEST_LABEL}={run}");
        let dir = TestDir::new("slimm-sup-docker");
        let registry = format!("slimm-test-reg-{run}");
        docker(&[
            "run",
            "-d",
            "--name",
            &registry,
            "--label",
            &label,
            "-p",
            "127.0.0.1::5000",
            "registry:2.8.3@sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373",
        ]);
        let mut stage = Self {
            registry_prefix: String::new(),
            probe_image: String::new(),
            own_image: format!("slimm-supervisor-test:{run}"),
            egress_network: format!("slimm-test-egress-{run}"),
            server_name: format!("slimm-test-server-{run}"),
            instances: Vec::new(),
            handles: Vec::new(),
            run,
            dir,
        };
        let port = docker(&["port", &registry, "5000/tcp"])
            .rsplit(':')
            .next()
            .unwrap()
            .to_owned();
        stage.registry_prefix = format!("127.0.0.1:{port}/slimm-test/");
        stage.build_own_image();
        stage.push_probe();
        docker(&[
            "network",
            "create",
            "--label",
            &label,
            &stage.egress_network,
        ]);
        let serve = concat!(
            "mkdir -p /www/cgi-bin && echo server-ok > /www/ok && ",
            "printf '#!/bin/sh\\necho Content-Type: text/plain\\necho\\nenv | grep ^HTTP_\\n' > /www/cgi-bin/h && ",
            "chmod +x /www/cgi-bin/h && exec httpd -f -p 8080 -h /www"
        );
        docker(&[
            "run",
            "-d",
            "--name",
            &stage.server_name,
            "--label",
            &label,
            "--network",
            &stage.egress_network,
            "busybox:1.37.0",
            "sh",
            "-c",
            serve,
        ]);
        stage
    }

    /// The test binary's own supervisor, with exactly the shared libraries it links, on scratch.
    fn build_own_image(&self) {
        let ctx = self.dir.0.join("own-image");
        let bin = env!("CARGO_BIN_EXE_slimm-supervisor");
        copy_into(&ctx, Path::new(bin), "usr/local/bin/slimm-supervisor");
        let ldd = Command::new("ldd").arg(bin).output().expect("ldd runs");
        for line in String::from_utf8_lossy(&ldd.stdout).lines() {
            let path = line
                .split("=>")
                .last()
                .unwrap_or_default()
                .split_whitespace()
                .next()
                .unwrap_or_default();
            if path.starts_with('/') {
                copy_into(&ctx, Path::new(path), path.trim_start_matches('/'));
            }
        }
        let dockerfile =
            "FROM scratch\nCOPY rootfs/ /\nENTRYPOINT [\"/usr/local/bin/slimm-supervisor\"]\n";
        std::fs::write(ctx.join("Dockerfile"), dockerfile).unwrap();
        let label = format!("{TEST_LABEL}={}", self.run);
        docker(&[
            "build",
            "-q",
            "--label",
            &label,
            "-t",
            &self.own_image,
            ctx.to_str().unwrap(),
        ]);
    }

    /// Pushes the probe to the local registry and drops the local copy, so create must pull it.
    fn push_probe(&mut self) {
        let tag = format!("{}probe:{}", self.registry_prefix, self.run);
        let ctx = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/probe");
        docker(&["build", "-q", "-t", &tag, ctx.to_str().unwrap()]);
        docker(&["push", "-q", &tag]);
        let digest = docker(&["inspect", "--format", "{{index .RepoDigests 0}}", &tag]);
        docker(&["rmi", &tag]);
        let _ = docker_ok(&["rmi", &digest]);
        self.probe_image = digest;
    }

    /// A running supervisor for a fresh instance id; `extra` overrides config keys.
    pub async fn supervisor(&mut self, extra: &[(&str, &str)]) -> (Client, String) {
        let instance = uuid::Uuid::now_v7().simple().to_string()[16..].to_owned();
        let sub = self.dir.0.join(format!("sup-{instance}"));
        std::fs::create_dir_all(&sub).unwrap();
        let server_url = format!("http://{}:8080", self.server_name);
        let mut keys: Vec<(&str, &str)> = vec![
            ("SLIMM_RUNTIME_SOCKET", "/var/run/docker.sock"),
            ("SLIMM_SUPERVISOR_IMAGE", &self.own_image),
            ("SLIMM_SUPERVISOR_REGISTRIES", &self.registry_prefix),
            ("SLIMM_SUPERVISOR_EGRESS_NETWORK", &self.egress_network),
            ("SLIMM_SUPERVISOR_SERVER_URL", &server_url),
        ];
        keys.extend_from_slice(extra);
        let mut config = config(&sub, &keys);
        config.requirements.lsm = daemon_has_lsm();
        let client = Client::new(&config.socket);
        self.handles.push(start(config, &instance).await);
        self.instances.push(instance.clone());
        (client, instance)
    }
}

/// A dev box whose daemon has neither AppArmor nor SELinux still runs the suite; CI's does not need this.
pub fn daemon_has_lsm() -> bool {
    let options = docker(&["info", "--format", "{{json .SecurityOptions}}"]);
    let has = options.contains("name=apparmor") || options.contains("name=selinux");
    if !has {
        eprintln!("SKIPPED the AppArmor/SELinux requirement: this daemon applies neither");
    }
    has
}

fn copy_into(ctx: &Path, from: &Path, to: &str) {
    let dest = ctx.join("rootfs").join(to);
    std::fs::create_dir_all(dest.parent().unwrap()).unwrap();
    std::fs::copy(from, &dest).unwrap();
}

/// Ids of every object of `kind` carrying the label.
fn labelled(kind: &str, label: &str) -> Vec<String> {
    let mut args = vec![kind, "ls", "-q", "--filter"];
    let filter = format!("label={label}");
    args.push(&filter);
    if kind == "container" {
        args.push("-a");
    }
    docker(&args).lines().map(str::to_owned).collect()
}

impl Drop for Stage {
    fn drop(&mut self) {
        for instance in &self.instances {
            let _ = std::fs::remove_file(socket_for(&self.dir.0.join(format!("sup-{instance}"))));
        }
        let mut labels = vec![format!("{TEST_LABEL}={}", self.run)];
        labels.extend(
            self.instances
                .iter()
                .map(|i| format!("org.slim-m.instance={i}")),
        );
        for label in &labels {
            for id in labelled("container", label) {
                let _ = docker_ok(&["rm", "-f", &id]);
            }
        }
        for label in &labels {
            for id in labelled("network", label) {
                let _ = docker_ok(&["network", "rm", &id]);
            }
            for id in labelled("volume", label) {
                let _ = docker_ok(&["volume", "rm", "-f", &id]);
            }
        }
        let _ = docker_ok(&["rmi", "-f", &self.own_image]);
        let _ = docker_ok(&["rmi", "-f", &self.probe_image]);
    }
}
