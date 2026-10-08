// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What a module run may reach through `slim.host_call`, per decision 0023.
//!
//! [`surface_for`] turns an installed module plus the invoking user into the
//! run's capability surface. Only a capability the manifest declared, the host
//! implements, and an admin approved at install is ever on it; a module with
//! none gets [`CapabilitySurface::Disabled`] and stays on the import-free ABI.
//!
//! `host_call` is a synchronous wasm import running on a blocking thread, so the
//! backends here `block_on` the async store from that thread. Each call is one
//! bounded query, and the per-run call budgets cap how many a run can make.

use std::sync::Arc;

use tokio::runtime::Handle;
use uuid::Uuid;

use super::AppState;
use super::channel_slow_mode::enforce_slow_mode;
use super::messages::validate_content;
use crate::hub::Event;
use crate::ids::{ChannelId, MessageId, UserId};
use crate::module_runtime::{
    CapabilitySurface, KvBackend, KvError, MAX_ENTRIES, MAX_TOTAL_BYTES, MessagePoster, PostRefused,
};
use crate::permissions::Permissions;
use crate::ratelimit::Class;
use crate::store::{InstalledModule, KvSetError, NewMessage, Store};

/// The capabilities this host implements behind `slim.host_call`. A manifest
/// may declare others (it is free text); none of them can ever be approved.
pub(crate) const HOST_CAPABILITIES: [&str; 2] = ["kv.store", "message.post"];

/// Most keys a `list` returns; equal to the entry cap, so it is never truncated.
const LIST_LIMIT: i64 = MAX_ENTRIES as i64;
/// Charged against the module as a whole for every post; see [`Class::ModulePost`].
const MODULE_WIDE_POST_COST: f64 = 0.25;

/// The host capabilities `module` may use: declared in its manifest, approved
/// by an admin, and implemented here. All three, or the capability is absent.
pub(crate) fn effective_capabilities(module: &InstalledModule) -> Vec<String> {
    module
        .approved_host_capabilities
        .iter()
        .filter(|c| HOST_CAPABILITIES.contains(&c.as_str()))
        .filter(|c| module.approved_capabilities.contains(c))
        .cloned()
        .collect()
}

/// The capability surface for one run of `module`, invoked by `user_id`.
/// Must be called from inside the tokio runtime that will drive the run.
///
/// `channel` is the channel the invoker ran the command from. Without one the
/// run is untrusted (a code block's text, or a caller that named no channel):
/// `message.post` stays approved but has no poster, so a call to it is refused
/// by name instead of the module being refused its import.
pub(crate) fn surface_for(
    state: &AppState,
    module: &InstalledModule,
    user_id: UserId,
    channel: Option<ChannelId>,
) -> CapabilitySurface {
    let approved = effective_capabilities(module);
    if approved.is_empty() {
        return CapabilitySurface::Disabled;
    }
    let handle = Handle::current();
    let kv = Arc::new(SqliteKv {
        store: state.store.clone(),
        handle: handle.clone(),
    });
    let surface = CapabilitySurface::enabled(approved, module.id.clone(), kv);
    let Some(channel) = channel else {
        return surface;
    };
    surface.with_poster(Arc::new(ChannelPoster {
        state: state.clone(),
        handle,
        module_id: module.id.clone(),
        module_name: module.name.clone(),
        user_id,
        channel,
    }))
}

struct SqliteKv {
    store: Store,
    handle: Handle,
}

impl KvBackend for SqliteKv {
    fn get(&self, module_id: &str, key: &str) -> Result<Option<String>, KvError> {
        self.handle
            .block_on(self.store.module_kv_get(module_id, key))
            .map_err(|_| KvError::Unavailable)
    }

    fn set(&self, module_id: &str, key: &str, value: &str) -> Result<(), KvError> {
        let outcome = self.handle.block_on(self.store.module_kv_set(
            module_id,
            key,
            value,
            MAX_ENTRIES as i64,
            MAX_TOTAL_BYTES as i64,
        ));
        match outcome {
            Ok(()) => Ok(()),
            Err(KvSetError::Full) => Err(KvError::Full),
            Err(KvSetError::Internal(_)) => Err(KvError::Unavailable),
        }
    }

    fn delete(&self, module_id: &str, key: &str) -> Result<(), KvError> {
        self.handle
            .block_on(self.store.module_kv_delete(module_id, key))
            .map_err(|_| KvError::Unavailable)
    }

    fn list(&self, module_id: &str) -> Result<Vec<String>, KvError> {
        self.handle
            .block_on(self.store.module_kv_keys(module_id, LIST_LIMIT))
            .map_err(|_| KvError::Unavailable)
    }
}

/// Posts as `user_id`, the user who invoked the module, and never as anyone
/// the module names.
struct ChannelPoster {
    state: AppState,
    handle: Handle,
    module_id: String,
    module_name: String,
    user_id: UserId,
    /// The one channel this run may post into: where the command was invoked.
    channel: ChannelId,
}

impl MessagePoster for ChannelPoster {
    fn post(&self, channel_id: Option<&str>, content: &str) -> Result<String, PostRefused> {
        self.handle
            .block_on(self.post_async(channel_id, content))
            .map(|id| id.to_string())
    }
}

impl ChannelPoster {
    /// The same checks a first-party send makes, evaluated for the invoking
    /// user, so a module can post exactly where that user could. A missing
    /// channel and a denied one are refused identically.
    async fn post_async(
        &self,
        named: Option<&str>,
        content: &str,
    ) -> Result<MessageId, PostRefused> {
        let state = &self.state;
        let channel_id = self.channel;
        if let Some(named) = named {
            let named = Uuid::parse_str(named)
                .map(ChannelId)
                .map_err(|_| PostRefused("invalid channel_id"))?;
            if named != channel_id {
                return Err(PostRefused(
                    "message.post can only post in the channel the command was run from",
                ));
            }
        }
        let needed = Permissions::VIEW_CHANNEL.union(Permissions::SEND_MESSAGES);
        match state
            .store
            .has_permission(self.user_id, channel_id, needed)
            .await
        {
            Ok(true) => {}
            Ok(false) => return Err(PostRefused("not permitted to post in that channel")),
            Err(_) => return Err(PostRefused("message.post is unavailable")),
        }
        self.charge_rate_limits()?;
        let content = validate_content(content, false)
            .map_err(|_| PostRefused("content is empty or too long"))?;
        let slow_mode_window_ms = enforce_slow_mode(state, channel_id, self.user_id)
            .await
            .map_err(|_| PostRefused("slow mode is active in that channel"))?;

        let id = MessageId::generate();
        let footer = format!("via {}", self.module_name);
        let sent = state
            .store
            .send_module_message_with_slow_mode(
                NewMessage::plain(channel_id, self.user_id, id, content),
                &self.module_id,
                &footer,
                slow_mode_window_ms,
            )
            .await
            .map_err(|_| PostRefused("message.post is unavailable"))?;

        // Committed with its attribution; nothing below may fail the call, or a retry duplicates it.
        self.fan_out(&sent.message).await;
        Ok(id)
    }

    /// Best-effort delivery of a message that is already stored and attributed.
    async fn fan_out(&self, message: &crate::store::Message) {
        let state = &self.state;
        let id = message.id;
        let embeds = match state.store.embeds_for_messages(&[id]).await {
            Ok(rows) => rows.into_iter().next().map(|(_, e)| e).unwrap_or_default(),
            Err(err) => {
                tracing::warn!(%err, "module post: could not reload embeds");
                Vec::new()
            }
        };
        if let Err(err) = super::message_mentions::resolve_and_store(
            state,
            message.channel_id,
            self.user_id,
            id,
            &message.content,
        )
        .await
        {
            tracing::warn!(%err, "module post: mention resolution failed");
        }
        super::read_sync::advance_for_author(state, self.user_id, message).await;
        state.hub.publish(Event::MessageCreated {
            message: Arc::new(message.clone()),
            attachments: Arc::new(Vec::new()),
            forwarded: None,
            app_surface: None,
            code_run: None,
            poll: None,
            embeds: Arc::new(embeds),
            call: None,
            components: Arc::new(Vec::new()),
            lookups: Default::default(),
        });
        state.push.notify_message(
            state.store.clone(),
            crate::push::SentMessage {
                channel_id: message.channel_id,
                author_id: self.user_id,
                message_id: id,
                seq: message.seq,
                content: message.content.clone(),
                presence: state.hub.presence(),
            },
        );
        super::threads::notify_reply(state, message.channel_id).await;
    }

    fn charge_rate_limits(&self) -> Result<(), PostRefused> {
        let limiter = &self.state.limiter;
        let per_user = format!("mu:{}:{}", self.module_id, self.user_id);
        let module_wide = format!("m:{}", self.module_id);
        if limiter.check(Class::ModulePost, &per_user)
            && limiter.check_weighted(Class::ModulePost, &module_wide, MODULE_WIDE_POST_COST)
        {
            Ok(())
        } else {
            Err(PostRefused("message.post rate limit reached"))
        }
    }
}
