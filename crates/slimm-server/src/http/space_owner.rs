// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Telling every client when Space ownership passes on, wherever the hand-off happened.

use super::AppState;
use crate::hub::Event;
use crate::ids::UserId;
use crate::store::Handoff;

/// The Space owner, handing ownership on first when the stored one is gone.
pub(in crate::http) async fn settled_owner(state: &AppState) -> anyhow::Result<Option<UserId>> {
    let ownership = state.store.settle_space_owner().await?;
    announce_handoff(state, ownership.handoff);
    Ok(ownership.owner)
}

/// The heir's profile now reads `is_owner`, their permissions moved, and a timeout on them ended.
pub(in crate::http) fn announce_handoff(state: &AppState, handoff: Option<Handoff>) {
    let Some(Handoff {
        heir,
        lifted_timeout,
    }) = handoff
    else {
        return;
    };
    if lifted_timeout {
        state.hub.publish(Event::MemberTimeoutChanged {
            user_id: heir,
            until: None,
        });
    }
    state.hub.publish(Event::ProfileChanged(heir));
    state.hub.publish(Event::OwnerChanged(heir));
}
