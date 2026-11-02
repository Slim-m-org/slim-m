// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What the operator sets, all by environment variable.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::path::PathBuf;

/// The shortest secret accepted, matching the server's own rule.
const MIN_SECRET_CHARS: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub listen: SocketAddr,
    /// The bearer secret the server presents.
    pub secret: String,
    pub model: PathBuf,
    /// `None` detects the language of each utterance.
    pub language: Option<String>,
    pub threads: usize,
    pub max_sessions: u32,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        Self::from_map(&std::env::vars().collect())
    }

    pub fn from_map(env: &HashMap<String, String>) -> anyhow::Result<Self> {
        let get = |key: &str| env.get(key).map(|v| v.trim()).filter(|v| !v.is_empty());
        let secret = get("LISTENER_SECRET").unwrap_or_default().to_owned();
        if secret.chars().count() < MIN_SECRET_CHARS {
            anyhow::bail!("LISTENER_SECRET must be at least {MIN_SECRET_CHARS} characters");
        }
        let language = get("WHISPER_LANGUAGE")
            .filter(|l| !l.eq_ignore_ascii_case("auto"))
            .map(str::to_owned);
        Ok(Self {
            listen: get("LISTENER_ADDR").unwrap_or("0.0.0.0:9400").parse()?,
            secret,
            model: get("WHISPER_MODEL")
                .unwrap_or("/models/ggml-base.bin")
                .into(),
            language,
            threads: number(get("LISTENER_THREADS"), 4)?.max(1) as usize,
            max_sessions: number(get("LISTENER_MAX_SESSIONS"), 2)?.max(1),
        })
    }
}

fn number(raw: Option<&str>, default: u32) -> anyhow::Result<u32> {
    raw.map_or(Ok(default), |v| Ok(v.parse()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), (*v).to_owned()))
            .collect()
    }

    const SECRET: &str = "0123456789abcdef0123456789abcdef";

    #[test]
    fn defaults_are_two_sessions_four_threads_and_auto_language() {
        let config = Config::from_map(&env(&[("LISTENER_SECRET", SECRET)])).unwrap();
        assert_eq!(config.max_sessions, 2);
        assert_eq!(config.threads, 4);
        assert_eq!(config.language, None);
        assert_eq!(config.model, PathBuf::from("/models/ggml-base.bin"));
    }

    #[test]
    fn a_missing_or_short_secret_is_refused() {
        assert!(Config::from_map(&env(&[])).is_err());
        assert!(Config::from_map(&env(&[("LISTENER_SECRET", "short")])).is_err());
    }

    #[test]
    fn language_auto_means_detect_and_a_code_is_kept() {
        let auto = env(&[("LISTENER_SECRET", SECRET), ("WHISPER_LANGUAGE", "AUTO")]);
        assert_eq!(Config::from_map(&auto).unwrap().language, None);
        let set = env(&[("LISTENER_SECRET", SECRET), ("WHISPER_LANGUAGE", "de")]);
        assert_eq!(
            Config::from_map(&set).unwrap().language.as_deref(),
            Some("de")
        );
    }

    #[test]
    fn numbers_come_from_the_environment() {
        let config = Config::from_map(&env(&[
            ("LISTENER_SECRET", SECRET),
            ("LISTENER_THREADS", "8"),
            ("LISTENER_MAX_SESSIONS", "3"),
        ]))
        .unwrap();
        assert_eq!((config.threads, config.max_sessions), (8, 3));
    }
}
