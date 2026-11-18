// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Redialling over and over re-rings the callee each time, so the ring route
//! itself is throttled per caller, whichever DM the rings go to.

use axum::http::StatusCode;

use crate::ring_audience::rig;

#[tokio::test]
async fn a_redial_flurry_is_refused_past_its_burst() {
    let rig = rig("slimm-ring-throttle").await;
    let alice = rig.person("alice").await;
    let bob = rig.person("bob").await;
    let cleo = rig.person("cleo").await;
    let to_bob = rig.open_dm(&alice, &bob).await;
    let to_cleo = rig.open_dm(&alice, &cleo).await;

    for _ in 0..5 {
        rig.ring(&to_bob, &alice).await;
    }
    for channel in [&to_bob, &to_cleo] {
        let response = rig
            .post(&format!("/channels/{channel}/voice/ring"), &alice)
            .await;
        assert_eq!(response.status(), StatusCode::TOO_MANY_REQUESTS);
    }
    rig.ring(&to_bob, &bob).await;
}
