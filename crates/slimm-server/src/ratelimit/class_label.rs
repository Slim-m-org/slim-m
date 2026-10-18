// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The Prometheus label for each [`Class`], split out of `class.rs` for the file budget.

use super::Class;

impl Class {
    /// The Prometheus label value for this class: lowercase, snake_case, and
    /// stable across releases since a dashboard or alert may key on it.
    pub fn label(self) -> &'static str {
        match self {
            Class::Password => "password",
            Class::Refresh => "refresh",
            Class::Ticket => "ticket",
            Class::Write => "write",
            Class::Typing => "typing",
            Class::Read => "read",
            Class::InviteCheck => "invite_check",
            Class::Upload => "upload",
            Class::Canvas => "canvas",
            Class::CanvasCursor => "canvas_cursor",
            Class::CanvasStrokePreview => "canvas_stroke_preview",
            Class::CanvasObjectPreview => "canvas_object_preview",
            Class::Asset => "asset",
            Class::Gif => "gif",
            Class::LinkPreview => "link_preview",
            Class::Ring => "ring",
            Class::AuthedRead => "authed_read",
            Class::Module => "module",
            Class::CodeRunner => "code_runner",
            Class::Webhook => "webhook",
            Class::LiveKitWebhook => "livekit_webhook",
            Class::Interaction => "interaction",
            Class::ModulePost => "module_post",
            Class::SignInAlert => "sign_in_alert",
            Class::PresenceActivity => "presence_activity",
            Class::Totp => "totp",
            Class::WatchTick => "watch_tick",
            Class::DiagnosticPing => "diagnostic_ping",
            Class::DiagnosticTransfer => "diagnostic_transfer",
        }
    }
}
