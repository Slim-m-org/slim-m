// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `start` does for real: join the LiveKit room, then run the session.

use std::sync::Arc;

use crate::control::Launcher;

/// The launcher for a build that can join LiveKit.
#[cfg(feature = "livekit-room")]
pub fn real() -> anyhow::Result<Arc<dyn Launcher>> {
    Ok(Arc::new(live::Live))
}

#[cfg(not(feature = "livekit-room"))]
pub fn real() -> anyhow::Result<Arc<dyn Launcher>> {
    anyhow::bail!("this build cannot join a room; build with the livekit-room feature")
}

#[cfg(feature = "livekit-room")]
mod live {
    use tokio::sync::mpsc::unbounded_channel;

    use crate::control::{Launch, Launcher, Running};
    use crate::protocol::Report;
    use crate::room::LiveKitRoom;
    use crate::session::{Params, run};

    pub struct Live;

    impl Launcher for Live {
        fn launch(&self, launch: Launch) -> Running {
            let (commands, feed) = unbounded_channel();
            let task = tokio::spawn(async move {
                let Launch {
                    session,
                    livekit_url,
                    token,
                    include,
                    language,
                    reports,
                    pool,
                } = launch;
                match LiveKitRoom::connect(&livekit_url, &token).await {
                    Ok(room) => {
                        let params = Params {
                            id: session,
                            include,
                            language,
                        };
                        run(params, room, feed, pool, reports).await;
                    }
                    Err(err) => {
                        tracing::warn!(%err, "could not join the room");
                        let _ = reports.send(Report::Ended {
                            session,
                            reason: "room_error".into(),
                        });
                    }
                }
            });
            Running { commands, task }
        }
    }
}
