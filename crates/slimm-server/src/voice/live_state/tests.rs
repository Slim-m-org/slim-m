// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Unit tests for [`super::RoomLiveState`].

use super::*;

fn uid() -> UserId {
    UserId::generate()
}

fn cid() -> ChannelId {
    ChannelId::generate()
}

#[test]
fn a_first_join_is_a_real_transition() {
    let state = RoomLiveState::new();
    assert!(state.mark_joined(cid(), uid(), "PA"));
}

#[test]
fn a_duplicate_join_webhook_does_not_republish() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    assert!(state.mark_joined(channel, user, "PA"));
    assert!(!state.mark_joined(channel, user, "PA"));
}

#[test]
fn a_leave_from_a_session_joined_before_a_restart_still_publishes() {
    let state = RoomLiveState::new();
    assert!(state.mark_left(cid(), uid(), "PA"));
}

#[test]
fn a_duplicate_leave_of_an_unknown_session_publishes_once() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    assert!(state.mark_left(channel, user, "PA"));
    assert!(!state.mark_left(channel, user, "PA"));
}

#[test]
fn a_rejoin_after_a_leave_publishes_its_own_leave() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.mark_left(channel, user, "PA"));
    assert!(state.mark_joined(channel, user, "PA"));
    assert!(state.mark_left(channel, user, "PA"));
}

#[test]
fn a_duplicate_leave_webhook_does_not_republish() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.mark_left(channel, user, "PA"));
    assert!(!state.mark_left(channel, user, "PA"));
}

#[test]
fn the_first_screen_share_track_starts_sharing() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.track_published(channel, (user, "PA"), "track-video"));
}

#[test]
fn a_second_screen_share_track_is_not_a_fresh_start() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.track_published(channel, (user, "PA"), "track-video"));
    assert!(!state.track_published(channel, (user, "PA"), "track-audio"));
}

#[test]
fn sharing_stops_only_once_every_screen_share_track_is_gone() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    state.track_published(channel, (user, "PA"), "track-video");
    state.track_published(channel, (user, "PA"), "track-audio");

    assert!(
        !state.track_unpublished(channel, (user, "PA"), "track-video"),
        "the audio track is still up"
    );
    assert!(
        state.track_unpublished(channel, (user, "PA"), "track-audio"),
        "that was the last screen-share track"
    );
}

#[test]
fn unpublishing_a_track_for_someone_unknown_reports_no_transition() {
    let state = RoomLiveState::new();
    assert!(!state.track_unpublished(cid(), (uid(), "PA"), "track-video"));
}

#[test]
fn a_track_published_before_any_join_webhook_still_counts() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    assert!(state.track_published(channel, (user, "PA"), "track-video"));
}

#[test]
fn a_duplicate_unpublish_is_not_a_second_stop() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    state.track_published(channel, (user, "PA"), "track-video");
    assert!(state.track_unpublished(channel, (user, "PA"), "track-video"));
    assert!(!state.track_unpublished(channel, (user, "PA"), "track-video"));
}

#[test]
fn a_join_after_an_early_track_still_publishes() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    assert!(state.track_published(channel, (user, "PA"), "track-video"));
    assert!(state.mark_joined(channel, user, "PA"));
    assert!(!state.mark_joined(channel, user, "PA"));
}

#[test]
fn a_late_track_after_leaving_does_not_swallow_the_next_join() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.mark_left(channel, user, "PA"));
    state.track_published(channel, (user, "PA"), "track-video");
    assert!(
        state.mark_joined(channel, user, "PB"),
        "the rejoin was swallowed"
    );
}

#[test]
fn a_late_leave_from_an_earlier_session_is_ignored() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    assert!(state.mark_joined(channel, user, "PB"));
    assert!(!state.mark_left(channel, user, "PA"));
    assert!(state.mark_left(channel, user, "PB"));
}

#[test]
fn a_finished_room_forgets_its_participants() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PA");
    state.forget_room(channel);
    assert!(state.mark_joined(channel, user, "PA"));
}

fn roster(users: &[(UserId, &str)]) -> Vec<(UserId, String, Option<i64>)> {
    users
        .iter()
        .map(|(u, sid)| (*u, (*sid).to_owned(), None))
        .collect()
}

fn stamped(users: &[(UserId, i64)]) -> Vec<(UserId, String, Option<i64>)> {
    users
        .iter()
        .map(|(u, at)| (*u, format!("PA_{u}"), Some(*at)))
        .collect()
}

#[test]
fn a_seeded_member_is_present_and_their_own_join_still_publishes_once() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.seed(channel, roster(&[(user, "PA")]));
    assert_eq!(state.present(channel), vec![user]);
    assert!(state.mark_joined(channel, user, "PA"));
    assert!(!state.mark_joined(channel, user, "PA"));
}

#[test]
fn a_seeded_member_leaving_publishes_the_leave() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.seed(channel, roster(&[(user, "PA")]));
    assert!(state.mark_left(channel, user, "PA"));
    assert!(state.present(channel).is_empty());
}

#[test]
fn seeding_never_brings_back_someone_whose_leave_was_already_published() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    assert!(state.mark_left(channel, user, "PA"));
    state.seed(channel, roster(&[(user, "PA")]));
    assert!(state.present(channel).is_empty());
}

#[test]
fn seeding_leaves_a_member_a_webhook_already_tracks_alone() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.mark_joined(channel, user, "PB");
    state.seed(channel, roster(&[(user, "PA")]));
    assert!(!state.mark_joined(channel, user, "PB"), "kept PB's entry");
}

#[test]
fn seeding_announces_a_member_a_track_webhook_only_hinted_at() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.track_published(channel, (user, "PA"), "track-video");
    assert!(state.present(channel).is_empty());
    state.seed(channel, roster(&[(user, "PA")]));
    assert_eq!(state.present(channel), vec![user]);
}

#[test]
fn a_seeded_member_who_joined_after_the_joiner_was_not_there_before_them() {
    let state = RoomLiveState::new();
    let (channel, early, late) = (cid(), uid(), uid());
    state.seed(channel, stamped(&[(early, 1_000), (late, 1_500)]));
    assert_eq!(state.present_before(channel, Some(1_200)), vec![early]);
    assert!(
        state.present_before(channel, Some(1_000)).is_empty(),
        "a tie is not before"
    );
    assert_eq!(
        state.present(channel).len(),
        2,
        "both are still on the call"
    );
}

#[test]
fn a_seeded_member_without_a_stamp_on_either_side_was_there_before() {
    let state = RoomLiveState::new();
    let (unstamped, stamped_channel, user) = (cid(), cid(), uid());
    state.seed(unstamped, roster(&[(user, "PA")]));
    assert_eq!(state.present_before(unstamped, Some(1_000)), vec![user]);
    state.seed(stamped_channel, stamped(&[(user, 5_000)]));
    assert_eq!(state.present_before(stamped_channel, None), vec![user]);
}

#[test]
fn a_member_whose_own_join_arrived_is_there_before_a_later_stamp() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.seed(channel, stamped(&[(user, 5_000)]));
    assert!(state.mark_joined(channel, user, &format!("PA_{user}")));
    assert_eq!(state.present_before(channel, Some(1_000)), vec![user]);
}

#[test]
fn a_member_the_sfu_gave_no_session_id_is_not_seeded() {
    let state = RoomLiveState::new();
    let (channel, user) = (cid(), uid());
    state.seed(channel, roster(&[(user, "")]));
    assert!(state.present(channel).is_empty());
    assert!(state.is_reconciled(channel));
}

#[test]
fn a_channel_is_reconciled_until_its_room_finishes() {
    let state = RoomLiveState::new();
    let channel = cid();
    assert!(!state.is_reconciled(channel));
    state.seed(channel, roster(&[]));
    assert!(state.is_reconciled(channel));
    state.forget_room(channel);
    assert!(!state.is_reconciled(channel));
}
