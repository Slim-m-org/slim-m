// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! Keeps the shared broadcast rings small: their memory is capacity times `size_of::<Event>()`.

use super::{CHANNEL_CAPACITY, EPHEMERAL_CHANNEL_CAPACITY, Event};

/// A variant carrying its payload inline rather than behind an `Arc` or `Box` trips this.
const MAX_EVENT_BYTES: usize = 192;

/// Upper bound for both rings together, so raising a capacity is a deliberate act.
const MAX_RING_BYTES: usize = 2 * 1024 * 1024;

#[test]
fn event_stays_small() {
    let size = std::mem::size_of::<Event>();
    assert!(
        size <= MAX_EVENT_BYTES,
        "Event is {size} bytes; box or Arc the large variant"
    );
}

#[test]
fn both_rings_stay_under_budget() {
    let ring = (CHANNEL_CAPACITY + EPHEMERAL_CHANNEL_CAPACITY) * std::mem::size_of::<Event>();
    assert!(ring <= MAX_RING_BYTES, "rings hold {ring} bytes");
}

#[test]
fn fanning_out_a_screen_annotation_shares_its_payload() {
    use super::{CanvasEvent, ScreenAnnotationEvent, ScreenAnnotationKind};
    use crate::ids::{ChannelId, UserId};

    let published = Event::Canvas(CanvasEvent::ScreenAnnotation(
        ScreenAnnotationEvent {
            channel_id: ChannelId::generate(),
            user_id: UserId::generate(),
            target_user_id: UserId::generate(),
            kind: ScreenAnnotationKind::Stroke,
            annotation_id: None,
            points: vec![0.1, 0.2, 0.3, 0.4],
            color: Some("red".to_owned()),
            text: None,
            ended: false,
            allowed: false,
            aspect: None,
        }
        .into(),
    ));
    let (
        Event::Canvas(CanvasEvent::ScreenAnnotation(first)),
        Event::Canvas(CanvasEvent::ScreenAnnotation(second)),
    ) = (published.clone(), published)
    else {
        panic!("clone changed the variant");
    };
    assert!(
        std::ptr::eq(&*first, &*second),
        "each subscriber got its own copy of the points"
    );
}
