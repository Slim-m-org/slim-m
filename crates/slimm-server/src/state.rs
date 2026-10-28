// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The handles every handler and background sweep shares.

use crate::auth::Auth;
use crate::code_runner::CodeRunner;
use crate::http::{dock, gifs, link_preview};
use crate::hub::Hub;
use crate::media::Media;
use crate::push::PushSender;
use crate::ratelimit::RateLimiter;
use crate::store::Store;
use crate::voice::VoiceService;

/// What every handler shares: the persistence layer, the auth service, and the
/// fan-out hub. Cloning is cheap (a pool handle and a couple of `Arc`s).
#[derive(Clone)]
pub struct AppState {
    pub store: Store,
    pub auth: Auth,
    pub hub: Hub,
    pub limiter: RateLimiter,
    pub push: PushSender,
    pub voice: VoiceService,
    pub media: Media,
    pub gifs: gifs::GifSearch,
    pub link_previews: link_preview::LinkPreviews,
    pub dock: dock::Dock,
    pub code_runner: CodeRunner,
}
