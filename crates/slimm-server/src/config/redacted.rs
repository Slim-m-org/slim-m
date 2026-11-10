// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! `Debug` for [`Config`] and [`ListenerSettings`] that says whether a secret is set and never
//! what it is. Both destructure every field, so a new one cannot be left out unnoticed.

use std::fmt;

use super::{Config, ListenerSettings};

struct Redacted<'a>(&'a Option<String>);

impl fmt::Debug for Redacted<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(if self.0.is_some() {
            "Some([redacted])"
        } else {
            "None"
        })
    }
}

impl fmt::Debug for Config {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Config {
            port,
            bind_address,
            database_path,
            data_key,
            hash_concurrency,
            push_relay_url,
            push_relay_key,
            livekit_url,
            livekit_api_key,
            livekit_api_secret,
            livekit_service_url,
            attachments_dir,
            modules_dir,
            attachment_max_bytes,
            max_total_attachment_bytes,
            gif_provider,
            gif_api_key,
            link_previews,
            cors_allowed_origins,
            trust_proxy_hops,
            addons_repo,
            dev_module_dir,
            code_runner_url,
            listener_url,
            listener_secret,
            listener_livekit_url,
            discord_client_id,
            discord_client_secret,
            discord_redirect_uri,
            backup_status_dir,
            alert_min_disk_free_mb,
        } = self;
        f.debug_struct("Config")
            .field("port", port)
            .field("bind_address", bind_address)
            .field("database_path", database_path)
            .field("data_key", &Redacted(data_key))
            .field("hash_concurrency", hash_concurrency)
            .field("push_relay_url", push_relay_url)
            .field("push_relay_key", &Redacted(push_relay_key))
            .field("livekit_url", livekit_url)
            .field("livekit_api_key", &Redacted(livekit_api_key))
            .field("livekit_api_secret", &Redacted(livekit_api_secret))
            .field("livekit_service_url", livekit_service_url)
            .field("attachments_dir", attachments_dir)
            .field("modules_dir", modules_dir)
            .field("attachment_max_bytes", attachment_max_bytes)
            .field("max_total_attachment_bytes", max_total_attachment_bytes)
            .field("gif_provider", gif_provider)
            .field("gif_api_key", &Redacted(gif_api_key))
            .field("link_previews", link_previews)
            .field("cors_allowed_origins", cors_allowed_origins)
            .field("trust_proxy_hops", trust_proxy_hops)
            .field("addons_repo", addons_repo)
            .field("dev_module_dir", dev_module_dir)
            .field("code_runner_url", code_runner_url)
            .field("listener_url", listener_url)
            .field("listener_secret", &Redacted(listener_secret))
            .field("listener_livekit_url", listener_livekit_url)
            .field("discord_client_id", discord_client_id)
            .field("discord_client_secret", &Redacted(discord_client_secret))
            .field("discord_redirect_uri", discord_redirect_uri)
            .field("backup_status_dir", backup_status_dir)
            .field("alert_min_disk_free_mb", alert_min_disk_free_mb)
            .finish()
    }
}

impl fmt::Debug for ListenerSettings {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let ListenerSettings {
            url,
            secret: _,
            livekit_url,
        } = self;
        f.debug_struct("ListenerSettings")
            .field("url", url)
            .field("secret", &"[redacted]")
            .field("livekit_url", livekit_url)
            .finish()
    }
}
