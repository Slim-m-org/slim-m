// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
use serde_json::value::RawValue;

use super::*;

fn key(module: &str, channel: ChannelId) -> RoomKey {
    RoomKey {
        module_id: module.to_owned(),
        channel_id: channel,
    }
}

fn state(text: &str) -> Next {
    Next {
        state: RoomJson::new(RawValue::from_string(text.to_owned()).unwrap()),
        scene: None,
    }
}

#[test]
fn a_room_that_never_got_a_state_is_not_kept() {
    let rooms = Rooms::default();
    let channel = ChannelId::generate();
    drop(rooms.enter(&key("game", channel)).unwrap());
    assert!(rooms.live().is_empty());

    let entered = rooms.enter(&key("game", channel)).unwrap();
    entered.room.commit(state("1"), 10).unwrap();
    drop(entered);
    let held = rooms.in_channel(channel);
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].1.seq, 1);
    assert_eq!(held[0].1.touched_at, 10);
}

#[test]
fn every_commit_moves_the_seq_by_one() {
    let rooms = Rooms::default();
    let entered = rooms.enter(&key("game", ChannelId::generate())).unwrap();
    let seqs: Vec<u64> = (0..3)
        .map(|n| entered.room.commit(state(&n.to_string()), n).unwrap().seq)
        .collect();
    assert_eq!(seqs, [1, 2, 3]);
}

#[test]
fn one_module_holds_a_bounded_number_of_rooms() {
    let rooms = Rooms::default();
    for _ in 0..MAX_ROOMS_PER_MODULE {
        let entered = rooms.enter(&key("game", ChannelId::generate())).unwrap();
        entered.room.commit(state("{}"), 0).unwrap();
    }
    let next = rooms.enter(&key("game", ChannelId::generate()));
    assert_eq!(next.err(), Some(Refused::TooManyRooms));
    assert!(rooms.enter(&key("other", ChannelId::generate())).is_ok());
}

#[test]
fn inputs_past_the_wait_limit_are_refused_and_leave_nothing_behind() {
    let rooms = Rooms::default();
    let room = key("game", ChannelId::generate());
    let waiting: Vec<_> = (0..MAX_WAITING)
        .map(|_| rooms.enter(&room).unwrap())
        .collect();
    assert_eq!(rooms.enter(&room).err(), Some(Refused::Busy));
    drop(waiting);
    assert!(rooms.live().is_empty());
}

#[test]
fn an_ended_room_takes_no_more_state_and_is_listed_no_more() {
    let rooms = Rooms::default();
    let channel = ChannelId::generate();
    let entered = rooms.enter(&key("game", channel)).unwrap();
    entered.room.commit(state("1"), 0).unwrap();
    let ended = rooms.end_where(|k, _| k.channel_id == channel);
    assert_eq!(ended.len(), 1);
    assert!(entered.room.commit(state("2"), 0).is_none());
    assert!(rooms.in_channel(channel).is_empty());
    drop(entered);
    let fresh = rooms.enter(&key("game", channel)).unwrap();
    assert_eq!(fresh.room.held().seq, 0);
}

#[test]
fn ending_reports_only_rooms_that_held_a_state() {
    let rooms = Rooms::default();
    let channel = ChannelId::generate();
    let _empty = rooms.enter(&key("quiet", channel)).unwrap();
    let busy = rooms.enter(&key("game", channel)).unwrap();
    busy.room.commit(state("1"), 0).unwrap();
    let ended = rooms.end_where(|_, _| true);
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].0.module_id, "game");
}
