// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The payload of [`super::Event::ConnectorRun`]: one member's run of a
//! connector's command or panel, forwarded to the connector (add-on API 7).

use uuid::Uuid;

use super::RoomJson;
use crate::ids::UserId;

/// The same run request a WASM module reads, addressed to one connector's principal.
#[derive(Debug, Clone)]
pub struct ConnectorRunRequest {
    /// The connector's principal; only its own connections receive the frame.
    pub principal: UserId,
    pub run_id: Uuid,
    pub module_id: String,
    /// How long the host waits for the answer, counted from when it sent the frame.
    pub deadline_ms: u64,
    pub request: RoomJson,
}
