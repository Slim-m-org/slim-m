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
    drop(
        rooms
            .enter(&key("game", channel), UserId::generate())
            .unwrap(),
    );
    assert!(rooms.live().is_empty());

    let entered = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    entered.room.commit(state("1"), 10, |_| {}).unwrap();
    drop(entered);
    let held = rooms.in_channel(channel);
    assert_eq!(held.len(), 1);
    assert_eq!(held[0].1.seq, 1);
    assert_eq!(held[0].1.touched_at, 10);
}

#[test]
fn every_commit_moves_the_seq_by_one() {
    let rooms = Rooms::default();
    let entered = rooms
        .enter(&key("game", ChannelId::generate()), UserId::generate())
        .unwrap();
    let seqs: Vec<u64> = (0..3)
        .map(|n| {
            entered
                .room
                .commit(state(&n.to_string()), n, |_| {})
                .unwrap()
                .seq
        })
        .collect();
    assert_eq!(seqs, [1, 2, 3]);
}

#[test]
fn one_module_holds_a_bounded_number_of_rooms() {
    let rooms = Rooms::default();
    for n in 0..MAX_ROOMS_PER_MODULE {
        let opener = UserId::generate();
        let entered = rooms
            .enter(&key("game", ChannelId::generate()), opener)
            .unwrap();
        entered.room.commit(state("{}"), n as i64, |_| {}).unwrap();
    }
    let next = rooms.enter(&key("game", ChannelId::generate()), UserId::generate());
    assert_eq!(next.err(), Some(Refused::TooManyRooms));
    assert!(
        rooms
            .enter(&key("other", ChannelId::generate()), UserId::generate())
            .is_ok()
    );
}

#[test]
fn one_member_cannot_use_up_a_modules_rooms_for_everyone() {
    let rooms = Rooms::default();
    let greedy = UserId::generate();
    for _ in 0..MAX_ROOMS_PER_OPENER {
        let entered = rooms
            .enter(&key("game", ChannelId::generate()), greedy)
            .unwrap();
        entered.room.commit(state("{}"), 0, |_| {}).unwrap();
    }
    let more = rooms.enter(&key("game", ChannelId::generate()), greedy);
    assert_eq!(more.err(), Some(Refused::TooManyOpened));
    assert!(
        rooms
            .enter(&key("other", ChannelId::generate()), greedy)
            .is_ok(),
        "the limit is per module"
    );
    assert!(
        rooms
            .enter(&key("game", ChannelId::generate()), UserId::generate())
            .is_ok(),
        "another member still opens a room"
    );
}

#[test]
fn a_member_joining_a_room_someone_else_opened_opens_nothing() {
    let rooms = Rooms::default();
    let joiner = UserId::generate();
    let channel = ChannelId::generate();
    let theirs = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    theirs.room.commit(state("{}"), 0, |_| {}).unwrap();
    for _ in 0..MAX_ROOMS_PER_OPENER {
        let entered = rooms
            .enter(&key("game", ChannelId::generate()), joiner)
            .unwrap();
        entered.room.commit(state("{}"), 0, |_| {}).unwrap();
    }
    assert!(rooms.enter(&key("game", channel), joiner).is_ok());
}

#[test]
fn inputs_past_the_wait_limit_are_refused_and_leave_nothing_behind() {
    let rooms = Rooms::default();
    let room = key("game", ChannelId::generate());
    let waiting: Vec<_> = (0..MAX_WAITING)
        .map(|_| rooms.enter(&room, UserId::generate()).unwrap())
        .collect();
    assert_eq!(
        rooms.enter(&room, UserId::generate()).err(),
        Some(Refused::Busy)
    );
    drop(waiting);
    assert!(rooms.live().is_empty());
}

#[test]
fn an_ended_room_takes_no_more_state_and_is_listed_no_more() {
    let rooms = Rooms::default();
    let channel = ChannelId::generate();
    let entered = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    entered.room.commit(state("1"), 0, |_| {}).unwrap();
    let ended = rooms.end_where(|k, _| k.channel_id == channel, |_, _| {});
    assert_eq!(ended.len(), 1);
    assert!(entered.room.commit(state("2"), 0, |_| {}).is_none());
    assert!(rooms.in_channel(channel).is_empty());
    drop(entered);
    let fresh = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    assert_eq!(fresh.room.held().seq, 0);
}

#[test]
fn ending_reports_only_rooms_that_held_a_state() {
    let rooms = Rooms::default();
    let channel = ChannelId::generate();
    let _empty = rooms
        .enter(&key("quiet", channel), UserId::generate())
        .unwrap();
    let busy = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    busy.room.commit(state("1"), 0, |_| {}).unwrap();
    let ended = rooms.end_where(|_, _| true, |_, _| {});
    assert_eq!(ended.len(), 1);
    assert_eq!(ended[0].0.module_id, "game");
}

/// Viewers are told in the order the room changed: a state frame never trails its `ended` frame.
#[test]
fn a_room_ending_while_a_state_is_announced_is_announced_after_it() {
    let rooms = Arc::new(Rooms::default());
    let channel = ChannelId::generate();
    let entered = rooms
        .enter(&key("game", channel), UserId::generate())
        .unwrap();
    let told = Arc::new(Mutex::new(Vec::new()));
    let mut ender = None;
    entered.room.commit(state("1"), 0, |_| {
        let (rooms, ended_told) = (Arc::clone(&rooms), Arc::clone(&told));
        ender = Some(std::thread::spawn(move || {
            rooms.end_where(|_, _| true, |_, _| ended_told.lock().unwrap().push("ended"));
        }));
        std::thread::sleep(std::time::Duration::from_millis(100));
        told.lock().unwrap().push("state");
    });
    ender.unwrap().join().unwrap();
    assert_eq!(*told.lock().unwrap(), ["state", "ended"]);
}
