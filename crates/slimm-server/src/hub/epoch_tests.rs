// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! What `publish` does besides sending: subscribers share one payload, and the
//! permissions epoch moves for exactly the events that move permissions.

use super::*;
use crate::ids::{ChannelId, RoleId, UserId};

/// Every subscriber receives a clone of the event; a large payload must be
/// shared by those clones, not copied once per connection (issue 2079).
#[test]
fn subscribers_share_a_large_payload_rather_than_copying_it() {
    let hub = Hub::new();
    let (mut first, mut second) = (hub.subscribe(), hub.subscribe());
    hub.publish(Event::Message(MessageEvent::ReactionsChanged {
        channel_id: ChannelId::generate(),
        message_id: crate::ids::MessageId::generate(),
        reactors: Arc::new(vec![("+1".to_owned(), vec![(UserId::generate(), 1)])]),
        moved: None,
    }));
    let reactors = |event| match event {
        Event::Message(MessageEvent::ReactionsChanged { reactors, .. }) => reactors,
        _ => panic!("wrong event"),
    };
    let (a, b) = (
        reactors(first.try_recv().unwrap()),
        reactors(second.try_recv().unwrap()),
    );
    assert!(Arc::ptr_eq(&a, &b));
}

/// The property the view cache rests on: the counter moves inside
/// `publish`, so it has already moved by the time anybody could receive
/// the event - and for a subscriber that never receives it at all.
///
/// That is the whole difference from invalidating as events arrive. A
/// connection lagging behind its queue would otherwise keep serving a
/// pre-revocation answer for every event still ahead of the revocation in
/// its own backlog, however long ago the write committed.
#[test]
fn the_epoch_moves_before_any_subscriber_receives() {
    let hub = Hub::new();
    let mut rx = hub.subscribe();
    let before = hub.permissions_epoch();

    hub.publish(Event::OverwriteChanged {
        channel_id: ChannelId::generate(),
        previously_visible_to: Arc::new(Vec::new()),
    });

    assert!(
        hub.permissions_epoch() > before,
        "the epoch must move without anybody having read the event yet",
    );
    assert!(rx.try_recv().is_ok(), "and the event is still delivered");
}

/// A clone is what every handler holds, so an epoch that did not travel
/// with it would move for nobody.
#[test]
fn a_clone_shares_the_same_counter() {
    let hub = Hub::new();
    let handle = hub.clone();
    let before = hub.permissions_epoch();
    handle.publish(Event::MemberRemoved {
        user_id: UserId::generate(),
        deleted: false,
    });
    assert!(hub.permissions_epoch() > before);
}

/// Ordinary traffic must not move it, or the cache never holds anything
/// and the whole change is a no-op with extra steps.
#[test]
fn channel_traffic_leaves_it_alone() {
    let hub = Hub::new();
    let before = hub.permissions_epoch();
    hub.publish(Event::TypingStarted {
        channel_id: ChannelId::generate(),
        user_id: UserId::generate(),
    });
    hub.publish(Event::presence_changed(UserId::generate()));
    hub.publish(Event::Message(MessageEvent::Deleted {
        op_seq: None,
        channel_id: ChannelId::generate(),
        message_id: crate::ids::MessageId::generate(),
    }));
    hub.publish(Event::VoiceActivityChanged {
        channel_id: ChannelId::generate(),
    });
    hub.publish(Event::MemberJoined(UserId::generate()));
    hub.publish(Event::Canvas(CanvasEvent::CursorMoved {
        channel_id: ChannelId::generate(),
        user_id: UserId::generate(),
        x: 0.0,
        y: 0.0,
        left: false,
    }));
    hub.publish(Event::Canvas(CanvasEvent::StrokePreview {
        channel_id: ChannelId::generate(),
        user_id: UserId::generate(),
        object_id: crate::ids::CanvasObjectId::generate(),
        points: Arc::new(vec![0.0, 0.0]),
        ended: false,
        cancelled: false,
        color: None,
        width: None,
    }));
    hub.publish(Event::Canvas(CanvasEvent::View {
        channel_id: ChannelId::generate(),
        user_id: UserId::generate(),
        x: 0.0,
        y: 0.0,
        w: 1.0,
        h: 1.0,
        summon: false,
        tile: None,
    }));
    hub.publish(Event::Canvas(CanvasEvent::ObjectPreview {
        channel_id: ChannelId::generate(),
        user_id: UserId::generate(),
        object_id: crate::ids::CanvasObjectId::generate(),
        x: 0.0,
        y: 0.0,
        w: 1.0,
        h: 1.0,
        ended: false,
    }));
    assert_eq!(hub.permissions_epoch(), before);
}

#[test]
fn every_permission_shaped_event_moves_it() {
    let hub = Hub::new();
    for event in [
        Event::RoleChanged {
            role_id: RoleId::generate(),
            change: None,
        },
        Event::MemberRoleChanged {
            user_id: UserId::generate(),
            role_id: RoleId::generate(),
            granted: true,
            role_name: None,
        },
        Event::MemberTimeoutChanged {
            user_id: UserId::generate(),
            until: Some(1),
        },
        Event::MemberRemoved {
            user_id: UserId::generate(),
            deleted: false,
        },
        Event::ChannelDeleted {
            channel_id: ChannelId::generate(),
        },
    ] {
        let before = hub.permissions_epoch();
        hub.publish(event);
        assert!(hub.permissions_epoch() > before);
    }
}
