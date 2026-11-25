// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use super::*;

fn set(ids: &[ChannelId]) -> HashSet<ChannelId> {
    ids.iter().copied().collect()
}

fn online(_: UserId) -> Option<Visibility> {
    Some(Visibility::Online)
}

fn hidden(_: UserId) -> Option<Visibility> {
    Some(Visibility::Hidden)
}

struct World {
    viewers: CanvasViewers,
    user: UserId,
    board: ChannelId,
}

fn world() -> World {
    World {
        viewers: CanvasViewers::default(),
        user: UserId::generate(),
        board: ChannelId::generate(),
    }
}

#[test]
fn the_first_connection_publishes_at_the_next_flush_and_a_second_does_not() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    assert_eq!(
        w.viewers.flush(online),
        vec![ViewerChange {
            channel_id: w.board,
            user_id: w.user,
            viewing: true
        }]
    );
    w.viewers.replace(w.user, 2, set(&[w.board]), 20);
    assert!(w.viewers.flush(online).is_empty());
}

#[test]
fn the_last_connection_out_publishes_and_an_earlier_one_does_not() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.replace(w.user, 2, set(&[w.board]), 20);
    w.viewers.flush(online);
    w.viewers.replace(w.user, 1, set(&[]), 30);
    assert!(w.viewers.flush(online).is_empty());
    w.viewers.replace(w.user, 2, set(&[]), 40);
    let changes = w.viewers.flush(online);
    assert_eq!(changes.len(), 1);
    assert!(!changes[0].viewing);
}

#[test]
fn a_disconnect_publishes_through_the_same_mark() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.flush(online);
    w.viewers.remove_connection(1);
    let changes = w.viewers.flush(online);
    assert_eq!(changes.len(), 1);
    assert!(!changes[0].viewing);
    assert!(w.viewers.open_channels().is_empty());
}

#[test]
fn a_replaced_declaration_diffs_both_ways() {
    let w = world();
    let other = ChannelId::generate();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.flush(online);
    w.viewers.replace(w.user, 1, set(&[other]), 20);
    let mut changes = w.viewers.flush(online);
    changes.sort_by_key(|c| c.viewing);
    assert_eq!(changes.len(), 2);
    assert_eq!(
        (changes[0].channel_id, changes[0].viewing),
        (w.board, false)
    );
    assert_eq!((changes[1].channel_id, changes[1].viewing), (other, true));
}

#[test]
fn open_close_open_inside_one_flush_publishes_one_join() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.replace(w.user, 1, set(&[]), 11);
    w.viewers.replace(w.user, 1, set(&[w.board]), 12);
    let changes = w.viewers.flush(online);
    assert_eq!(changes.len(), 1);
    assert!(changes[0].viewing);
}

#[test]
fn open_then_close_inside_one_flush_publishes_nothing() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.replace(w.user, 1, set(&[]), 11);
    assert!(w.viewers.flush(online).is_empty());
}

#[test]
fn a_hundred_toggles_publish_at_most_one_frame_per_pair_per_flush() {
    let w = world();
    for n in 0..100 {
        let channels = if n % 2 == 0 {
            set(&[w.board])
        } else {
            set(&[])
        };
        w.viewers.replace(w.user, 1, channels, n);
    }
    assert!(w.viewers.flush(online).is_empty());
    w.viewers.replace(w.user, 1, set(&[w.board]), 200);
    assert_eq!(w.viewers.flush(online).len(), 1);
    assert!(w.viewers.flush(online).is_empty());
}

#[test]
fn a_hidden_user_publishes_nothing_on_open_or_close() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    assert!(w.viewers.flush(hidden).is_empty());
    w.viewers.replace(w.user, 1, set(&[]), 20);
    assert!(w.viewers.flush(hidden).is_empty());
}

#[test]
fn turning_hidden_publishes_a_leave_and_turning_visible_a_join() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.flush(online);
    w.viewers.mark_user_dirty(w.user);
    let leave = w.viewers.flush(hidden);
    assert_eq!(leave.len(), 1);
    assert!(!leave[0].viewing);
    w.viewers.mark_user_dirty(w.user);
    let join = w.viewers.flush(online);
    assert_eq!(join.len(), 1);
    assert!(join[0].viewing);
}

#[test]
fn closing_a_board_drops_its_entries_and_resets_what_was_published_without_a_frame() {
    let w = world();
    w.viewers.replace(w.user, 1, set(&[w.board]), 10);
    w.viewers.flush(online);
    w.viewers.close_channel(w.board);
    assert!(w.viewers.flush(online).is_empty());
    assert!(w.viewers.entries(w.board).is_empty());
    assert!(w.viewers.channels_of(1).is_empty());
    w.viewers.replace(w.user, 1, set(&[w.board]), 20);
    assert_eq!(w.viewers.flush(online).len(), 1);
}

#[test]
fn viewer_shown_fails_closed_without_a_known_visibility() {
    let mut entry = Entry::new();
    entry.insert(1, 5);
    assert!(viewer_shown(&entry, Some(Visibility::Away)));
    assert!(!viewer_shown(&entry, None));
    assert!(!viewer_shown(&Entry::new(), Some(Visibility::Online)));
    assert_eq!(since(&entry), Some(5));
}
