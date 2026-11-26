// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Piper as a subprocess: one process per line, text on stdin, raw 16-bit mono
//! PCM on stdout at the voice's own sample rate.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use anyhow::Context;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::speak::{Boxed, Speech, Synthesizer};

/// A line that takes longer than this to synthesise is abandoned and its process killed.
const SYNTH_TIMEOUT: Duration = Duration::from_secs(20);

pub struct Piper {
    bin: PathBuf,
    model: PathBuf,
    sample_rate: u32,
}

impl Piper {
    /// Reads the voice's sample rate from the `.json` that ships beside its model.
    pub fn new(bin: PathBuf, model: PathBuf) -> anyhow::Result<Self> {
        let config = Self::config_path(&model);
        let raw = std::fs::read_to_string(&config)
            .with_context(|| format!("reading the voice config {}", config.display()))?;
        let sample_rate = sample_rate_of(&raw)?;
        Ok(Self {
            bin,
            model,
            sample_rate,
        })
    }

    fn config_path(model: &Path) -> PathBuf {
        let mut name = model.as_os_str().to_owned();
        name.push(".json");
        PathBuf::from(name)
    }

    async fn run(&self, text: &str) -> anyhow::Result<Vec<i16>> {
        let mut child = Command::new(&self.bin)
            .arg("-m")
            .arg(&self.model)
            .arg("--output-raw")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .with_context(|| format!("starting {}", self.bin.display()))?;
        let mut stdin = child.stdin.take().context("piper has no stdin")?;
        stdin.write_all(text.as_bytes()).await?;
        stdin.write_all(b"\n").await?;
        drop(stdin);
        let output = child.wait_with_output().await?;
        anyhow::ensure!(
            output.status.success(),
            "piper exited with {}",
            output.status
        );
        Ok(output
            .stdout
            .chunks_exact(2)
            .map(|pair| i16::from_le_bytes([pair[0], pair[1]]))
            .collect())
    }
}

impl Synthesizer for Piper {
    fn synthesize<'a>(&'a self, text: &'a str) -> Boxed<'a, Speech> {
        Box::pin(async move {
            let samples = tokio::time::timeout(SYNTH_TIMEOUT, self.run(text))
                .await
                .context("piper took too long")??;
            Ok(Speech {
                samples,
                sample_rate: self.sample_rate,
            })
        })
    }
}

fn sample_rate_of(config: &str) -> anyhow::Result<u32> {
    let value: serde_json::Value = serde_json::from_str(config)?;
    let rate = value["audio"]["sample_rate"]
        .as_u64()
        .context("the voice config has no audio.sample_rate")?;
    Ok(u32::try_from(rate)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_sample_rate_is_read_from_the_voice_config() {
        assert_eq!(
            sample_rate_of(r#"{"audio":{"sample_rate":22050}}"#).unwrap(),
            22050
        );
        assert!(sample_rate_of(r#"{"audio":{}}"#).is_err());
        assert!(sample_rate_of("nope").is_err());
    }

    #[tokio::test]
    async fn a_stand_in_binary_that_prints_pcm_is_read_back_as_samples() {
        let dir = std::env::temp_dir().join(format!("piper-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let bin = dir.join("fake-piper.sh");
        std::fs::write(
            &bin,
            "#!/bin/sh\ncat >/dev/null\nprintf '\\001\\000\\002\\000'\n",
        )
        .unwrap();
        std::fs::set_permissions(&bin, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        let model = dir.join("voice.onnx");
        std::fs::write(&model, "").unwrap();
        std::fs::write(
            dir.join("voice.onnx.json"),
            r#"{"audio":{"sample_rate":16000}}"#,
        )
        .unwrap();
        let piper = Piper::new(bin, model).unwrap();
        let speech = piper.synthesize("hello").await.unwrap();
        assert_eq!((speech.samples, speech.sample_rate), (vec![1, 2], 16000));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_failing_binary_is_an_error() {
        let dir = std::env::temp_dir().join(format!("piper-fail-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("v.onnx.json"),
            r#"{"audio":{"sample_rate":16000}}"#,
        )
        .unwrap();
        let piper = Piper::new(PathBuf::from("/bin/false"), dir.join("v.onnx")).unwrap();
        assert!(piper.synthesize("hello").await.is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
