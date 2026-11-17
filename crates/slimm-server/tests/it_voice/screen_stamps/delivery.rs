// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Who hears a stamp: everyone in the call, as with any other screen mark, and nobody outside it.

use axum::http::StatusCode;

use super::{KIND, PARTY, read_stamp, rig};
use crate::support::ws::assert_no_frame_of_type;

#[tokio::test]
async fn a_stamp_reaches_the_call_and_no_one_outside_it_with_canvas_access() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut sharer_ws = rig.socket(&rig.sharer).await;
    let mut carol_ws = rig.socket(&rig.carol).await;
    let mut dave_ws = rig.socket(&rig.dave).await;

    let body = rig.emoji(PARTY);
    let (status, error) = rig.stamp(&rig.viewer.token, body.clone()).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");

    for ws in [&mut sharer_ws, &mut carol_ws] {
        let frame = read_stamp(ws).await;
        assert_eq!(frame["annotation_id"], body["id"]);
        assert_eq!(frame["user_id"], rig.viewer.id.to_string());
    }
    assert_no_frame_of_type(&mut dave_ws, KIND).await;
}

#[tokio::test]
async fn someone_who_leaves_the_call_stops_hearing_its_stamps() {
    let rig = rig().await;
    rig.consent(true, true);
    let mut carol_ws = rig.socket(&rig.carol).await;
    rig.seat(&[rig.sharer.id, rig.viewer.id], &[rig.sharer.id]);

    let (status, error) = rig.stamp(&rig.viewer.token, rig.emoji(PARTY)).await;
    assert_eq!(status, StatusCode::NO_CONTENT, "{error}");

    assert_no_frame_of_type(&mut carol_ws, KIND).await;
}
