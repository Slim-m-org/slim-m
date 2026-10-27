// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Runtime configuration, loaded from `SLIMM_`-prefixed environment variables.
//!
//! Flat environment-variable config keeps the self-host operational surface
//! minimal: a single Docker Compose deployment sets a handful of variables and
//! nothing more.

use serde::Deserialize;

#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// TCP port the HTTP and WebSocket surface binds to.
    #[serde(default = "default_port")]
    pub port: u16,

    /// Filesystem path to the embedded SQLite database file.
    #[serde(default = "default_database_path")]
    pub database_path: String,

    /// Base64 of the 32-byte key that seals stored two-factor secrets. Blank reads as unset, and
    /// the key then lives in a file beside the database; see docs/OPERATING.md.
    #[serde(default, deserialize_with = "blank_as_none")]
    pub data_key: Option<String>,

    /// How many Argon2id password hashes may run at once. Each costs ~19 MiB, so
    /// this caps the transient memory a burst of logins can claim; requests over
    /// the limit wait on the semaphore rather than piling that memory up.
    #[serde(default = "default_hash_concurrency")]
    pub hash_concurrency: usize,

    /// Base URL of the push relay (for example `https://relay.example.com`);
    /// `/v1/send` is appended when calling it. Blank reads as unset.
    #[serde(default, deserialize_with = "blank_as_none")]
    pub push_relay_url: Option<String>,
    /// Bearer key this deployment authenticates to the relay with.
    ///
    /// Both push settings are optional together: a LAN-only or
    /// NAT-unreachable self-host has nowhere for a relay to reach it, and
    /// running with push disabled is a supported first-class configuration,
    /// not an error.
    pub push_relay_key: Option<String>,

    /// The LiveKit SFU clients connect to, for example
    /// `wss://livekit.example.com`. Handed to the client alongside a token,
    /// so it is the address reachable from outside, not the compose-internal
    /// one.
    pub livekit_url: Option<String>,
    /// API key the SFU knows this deployment by.
    pub livekit_api_key: Option<String>,
    /// The matching secret, which room tokens are signed with.
    ///
    /// All three LiveKit settings are optional together, and a deployment
    /// without them simply has no voice: the same first-class two-state shape
    /// as push above, because a text-only self-host is a supported way to run
    /// this and should not need to stand up an SFU to start.
    pub livekit_api_secret: Option<String>,
    /// Where this server reaches the SFU's room service, when that differs from
    /// [`Self::livekit_url`]: the compose-internal address skips the public
    /// proxy hop on every roster and kick call.
    pub livekit_service_url: Option<String>,

    /// Directory attachment and avatar bytes are stored under, beside the
    /// database rather than in it. A sibling of the database's own default
    /// (`data/slimm.db`), so a local `cargo run` gets both without any
    /// configuration, and the container image overrides both to absolute
    /// paths under the same mounted volume (see `docker/server.Dockerfile`).
    #[serde(default = "default_attachments_dir")]
    pub attachments_dir: String,

    /// Directory holding one data file per installed module; `None` means a
    /// `modules` directory beside the database file.
    #[serde(default)]
    pub modules_dir: Option<String>,

    /// Largest attachment a single upload may store, in bytes.
    #[serde(default = "default_attachment_max_bytes")]
    pub attachment_max_bytes: u64,

    /// Most bytes the deployment will hold in stored attachments and custom
    /// emoji together, or `None` for no ceiling. Open resumable upload sessions
    /// count at their declared size until they finish, are discarded or expire.
    ///
    /// `None` is the default because the right number is the operator's disk,
    /// not ours, and a guess would either refuse a legitimate upload on a large
    /// volume or do nothing on a small one. The shipped compose stack sets a
    /// concrete value, the same way it does for `SLIMM_TRUST_PROXY_HOPS`, so a
    /// self-host that follows the guide gets one without having to know it
    /// exists.
    ///
    /// Avatars are deliberately outside it. They live in their own directory,
    /// one file per account overwritten in place, so their total is bounded by
    /// the member count times `AVATAR_MAX_BYTES` and no upload can grow it -
    /// and they are not rows in `attachments`, so the sum this is checked
    /// against cannot see them anyway. Counting them would need a second
    /// mechanism to bound something that is already bounded.
    #[serde(default, deserialize_with = "empty_as_none")]
    pub max_total_attachment_bytes: Option<u64>,

    /// Which third-party GIF search provider this deployment proxies to:
    /// `tenor` or `klipy`, case-insensitively. Unset or empty means no GIF
    /// search at all - empty is read the same as unset because Compose's
    /// `${VAR:-}` interpolation hands the container an empty string rather
    /// than omitting the variable, the same reason `cors_allowed_origins`
    /// treats the two alike - and unrecognized text is a startup error
    /// rather than a silent fallback, the same treatment an unsafe relay
    /// URL scheme gets.
    ///
    /// Both this and `gif_api_key` must be set together, the same two-state
    /// shape push and LiveKit above already use: a self-host with no key for
    /// either provider simply has no GIF search, a fully supported
    /// deployment. The proxy exists so a client's search and every thumbnail
    /// it renders reach the provider through this server rather than
    /// directly, keeping members' own IP addresses away from Tenor or Klipy;
    /// see [`crate::http::gifs`].
    pub gif_provider: Option<String>,
    /// The operator's API key for whichever provider `gif_provider` names.
    pub gif_api_key: Option<String>,

    /// Whether the server unfurls pasted links into preview cards. Off by
    /// default because it makes the server issue outbound requests to
    /// arbitrary, member-supplied URLs; every such fetch runs behind the
    /// SSRF guard described in decision 0019. Set `SLIMM_LINK_PREVIEWS=true`
    /// to turn it on.
    #[serde(default)]
    pub link_previews: bool,

    /// Browser origins allowed to call this deployment cross-origin, comma
    /// separated, for example `https://app.example.com,http://localhost:8099`.
    ///
    /// Unset or empty means no CORS layer at all, and a browser on any other
    /// origin is refused. Native clients send no `Origin` and are unaffected,
    /// so only a web build of the client needs this; see [`crate::cors`] for
    /// why that default is the safe one.
    pub cors_allowed_origins: Option<String>,

    /// How many reverse proxies in front of this server may be believed about
    /// who an unauthenticated caller is, for rate limiting.
    ///
    /// Zero, the default, believes none of them and keys on the TCP peer, which
    /// is the only safe answer for a directly-exposed server: `X-Forwarded-For`
    /// is unsigned and anyone may send one.
    ///
    /// Set it to the number of proxies you actually run - 1 behind the Caddy in
    /// `deploy/` - and the address that many places from the right of that
    /// header is used instead. Counting from the right is what makes it safe;
    /// see `http::extract::limit_key`.
    ///
    /// Getting it wrong is not equally bad in both directions. Too low keys
    /// every unauthenticated caller together, so one of them can hold a bucket
    /// empty for everybody. Too high reads an address the client chose, so each
    /// caller can mint unlimited buckets. Neither is silent in the logs, but
    /// only the second is a bypass, which is why the default is zero.
    #[serde(default)]
    pub trust_proxy_hops: usize,

    /// The `owner/repo` the Dock's marketplace browses and installs from
    /// (see docs/decisions/0021-modules-and-the-dock.md). The Dock always
    /// reaches it at `https://raw.githubusercontent.com/<repo>/main/`; only
    /// the repo slug is configurable, never the host, so the marketplace
    /// fetch stays inside the same fixed allowlist regardless of what an
    /// operator sets here. See [`Config::addons_repos`] for the one slug the
    /// Dock may fall back to.
    #[serde(default = "default_addons_repo")]
    pub addons_repo: String,

    /// A directory laid out like a module registry (`index.json`,
    /// `modules/<id>/...`) the Dock offers as an extra, unverified source named
    /// `dev`, so a module author can install a build without publishing it.
    /// Unset is the default and keeps the source, and its routes, absent. An
    /// operator tool: set it only on a deployment you are developing against.
    #[serde(default, deserialize_with = "blank_as_none")]
    pub dev_module_dir: Option<String>,

    /// Base URL of a self-hosted Piston instance (engineer-man/piston), for
    /// example `http://piston:2000` on a compose-internal network; the
    /// `/api/v2/...` paths are appended when calling it. See
    /// `crate::code_runner` for the whole broker.
    ///
    /// Optional, and absent is the default and fully supported state: a
    /// deployment that never sets this behaves exactly as it does today,
    /// with no Run affordance on any code block and nothing resembling a
    /// startup error - the same first-class two-state shape `push_relay_url`
    /// above already has. slim-m runs no runner of its own and executes
    /// nothing itself; this only ever points at a Piston instance the
    /// operator stood up and trusts, the same relationship this project
    /// already has with the push relay and a self-hosted LiveKit. Blank reads
    /// as unset.
    #[serde(default, deserialize_with = "blank_as_none")]
    pub code_runner_url: Option<String>,

    /// The Discord application members link their accounts through
    /// (`/me/links/discord/start`). All three set turns linking on; blank
    /// reads as unset, and a deployment without them simply has no Discord
    /// link. The redirect URI must be the one registered with Discord,
    /// ending in `/links/discord/callback` on this server's public address.
    #[serde(default, deserialize_with = "blank_as_none")]
    pub discord_client_id: Option<String>,
    #[serde(default, deserialize_with = "blank_as_none")]
    pub discord_client_secret: Option<String>,
    #[serde(default, deserialize_with = "blank_as_none")]
    pub discord_redirect_uri: Option<String>,
}

fn default_port() -> u16 {
    8080
}

fn default_database_path() -> String {
    "data/slimm.db".to_owned()
}

fn default_hash_concurrency() -> usize {
    4
}

fn default_attachments_dir() -> String {
    "data/media".to_owned()
}

/// 1 GiB, forty times Discord's free 25 MiB. Safe as a default because a
/// self-hosted operator owns the disk, can bound total use with
/// `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES`, and can lower this per instance. The
/// upload path streams the body to disk while hashing it (see
/// `http::attachments::upload`), so a ceiling this high costs a bounded amount
/// of memory per upload rather than one that scales with the file's size.
fn default_attachment_max_bytes() -> u64 {
    1024 * 1024 * 1024
}

/// The official module registry's home since the move to the Slim-m-org
/// GitHub organisation.
pub const OFFICIAL_ADDONS_REPO: &str = "Slim-m-org/slim-addons";

/// Where the official registry lived before that move, kept as a fallback
/// because the Dock does not follow redirects.
pub const LEGACY_ADDONS_REPO: &str = "NC1107/slim-addons";

fn default_addons_repo() -> String {
    OFFICIAL_ADDONS_REPO.to_owned()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            port: default_port(),
            database_path: default_database_path(),
            data_key: None,
            hash_concurrency: default_hash_concurrency(),
            push_relay_url: None,
            push_relay_key: None,
            livekit_url: None,
            livekit_api_key: None,
            livekit_api_secret: None,
            livekit_service_url: None,
            attachments_dir: default_attachments_dir(),
            modules_dir: None,
            attachment_max_bytes: default_attachment_max_bytes(),
            max_total_attachment_bytes: None,
            gif_provider: None,
            gif_api_key: None,
            link_previews: false,
            cors_allowed_origins: None,
            trust_proxy_hops: 0,
            addons_repo: default_addons_repo(),
            dev_module_dir: None,
            code_runner_url: None,
            discord_client_id: None,
            discord_client_secret: None,
            discord_redirect_uri: None,
        }
    }
}

/// Reads an optional number, treating an empty string as absent.
///
/// `envy` hands every variable through as a string, and a compose file that
/// writes `SLIMM_MAX_TOTAL_ATTACHMENT_BYTES: ${VAR:-}` produces `""` rather
/// than an unset variable. Without this that empty value reaches `u64`'s own
/// parser and the process exits with "cannot parse integer from empty
/// string", which is how the shipped self-host example came to be unable to
/// start at all. Blank means "no ceiling", which is what leaving the line
/// alone is plainly meant to say.
fn empty_as_none<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Option::<String>::deserialize(deserializer)?;
    match raw.as_deref().map(str::trim) {
        None | Some("") => Ok(None),
        Some(value) => value.parse().map(Some).map_err(serde::de::Error::custom),
    }
}

/// Reads an optional string, treating blank as absent, for the same compose
/// `${VAR:-}` reason as [`empty_as_none`]: a blank sidecar URL must mean "off",
/// not a startup error about a URL with no scheme.
fn blank_as_none<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let raw = Option::<String>::deserialize(deserializer)?;
    Ok(raw
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty()))
}

impl Config {
    /// The LiveKit URL, key and secret, but only when all three carry a value.
    ///
    /// Blank is absent rather than configured. `envy` reads
    /// `SLIMM_LIVEKIT_URL=` as `Some("")` rather than `None` - the same
    /// behaviour `an_empty_origin_list_is_read_as_an_empty_string_not_dropped`
    /// pins for CORS - so a compose file that helpfully defaults the trio to
    /// empty strings would otherwise light up the enabled path and kill the
    /// process on a URL with no scheme. A text-only deployment must not be
    /// able to break itself by leaving voice alone, so the trimming lives
    /// here rather than at the call site.
    pub fn livekit_settings(&self) -> Option<(String, String, String)> {
        let present = |value: &Option<String>| {
            value
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        };
        Some((
            present(&self.livekit_url)?,
            present(&self.livekit_api_key)?,
            present(&self.livekit_api_secret)?,
        ))
    }

    /// The room service address override, blank read as absent like the trio.
    pub fn livekit_service_url(&self) -> Option<String> {
        self.livekit_service_url
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    }

    /// The official registry slugs the Dock tries, in order. Either of the
    /// two official slugs also tries the other one, so a server keeps its
    /// catalog on both sides of the organisation move without following a
    /// redirect; any other slug is an operator's own registry and is tried
    /// alone.
    pub fn addons_repos(&self) -> Vec<String> {
        let repo = self.addons_repo.trim();
        let other = if repo.eq_ignore_ascii_case(OFFICIAL_ADDONS_REPO) {
            Some(LEGACY_ADDONS_REPO)
        } else if repo.eq_ignore_ascii_case(LEGACY_ADDONS_REPO) {
            Some(OFFICIAL_ADDONS_REPO)
        } else {
            None
        };
        std::iter::once(repo.to_owned())
            .chain(other.map(str::to_owned))
            .collect()
    }

    /// Reads configuration from `SLIMM_`-prefixed environment variables,
    /// for example `SLIMM_PORT` and `SLIMM_DATABASE_PATH`.
    pub fn from_env() -> anyhow::Result<Self> {
        let config = envy::prefixed("SLIMM_").from_env::<Config>()?;
        Ok(config)
    }
}

#[cfg(test)]
mod tests;
