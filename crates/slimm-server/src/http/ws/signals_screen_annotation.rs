// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The screen-annotation signal: viewers' marks over a shared screen, and the sharer's consent for them.

use super::canvas_gate::{Frame, may_relay};
use super::permission_cache::PermissionCache;
use super::signals_canvas::valid_preview_color;
use crate::hub::{Event, Hub, ScreenAnnotationEvent, ScreenAnnotationKind};
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::{Class, RateLimiter};
use crate::store::{SessionContext, Store};

/// One `canvas.screen_annotation` frame's fields.
pub(super) struct ScreenAnnotationFrame {
    pub(super) channel_id: String,
    pub(super) target_user_id: String,
    pub(super) kind: String,
    pub(super) annotation_id: Option<String>,
    pub(super) points: Vec<f64>,
    pub(super) color: Option<String>,
    pub(super) text: Option<String>,
    pub(super) ended: bool,
    pub(super) allowed: bool,
    pub(super) aspect: Option<f64>,
}

/// Most coordinate pairs one annotation frame may carry.
const MAX_ANNOTATION_POINTS: usize = 24;

/// Longest sticky-note text relayed, in characters.
const MAX_ANNOTATION_TEXT_CHARS: usize = 80;

/// Widest and narrowest screen shape a consent frame may claim.
const ASPECT_RANGE: std::ops::RangeInclusive<f64> = 0.2..=10.0;

/// Relays a screen annotation, or a sharer's consent, on a channel's canvas.
///
/// Gated like ink (canvas access and not timed out) and charged by wire size
/// against the stroke-preview budget. A consent frame is only believed from
/// the sharer it speaks for. The server cannot know whether the sharer opted
/// in: the sharer's own client drops every annotation it did not allow, which
/// is the gate that matters because the overlay lives on that machine.
/// Silent on every rejection.
pub(super) async fn handle_canvas_screen_annotation(
    store: &Store,
    hub: &Hub,
    limiter: &RateLimiter,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    frame: ScreenAnnotationFrame,
    frame_bytes: usize,
) {
    let Some(event) = checked_annotation(ctx.user_id, frame) else {
        return;
    };
    let key = format!("u:{}", ctx.user_id);
    if !limiter.check_weighted(Class::CanvasStrokePreview, &key, frame_bytes as f64) {
        return;
    }
    hub.presence().touch(ctx.user_id);
    if !may_relay(store, hub, ctx, cache, event.channel_id, Frame::Ink).await {
        return;
    }
    hub.publish(Event::CanvasScreenAnnotation(Box::new(event)));
}

/// The relayed event for a well-formed frame from `sender`, or none.
fn checked_annotation(
    sender: UserId,
    frame: ScreenAnnotationFrame,
) -> Option<ScreenAnnotationEvent> {
    let channel_id = ChannelId(uuid::Uuid::parse_str(&frame.channel_id).ok()?);
    let target_user_id = UserId(uuid::Uuid::parse_str(&frame.target_user_id).ok()?);
    let kind = ScreenAnnotationKind::parse(&frame.kind)?;
    let annotation_id = match &frame.annotation_id {
        Some(raw) => Some(uuid::Uuid::parse_str(raw).ok()?),
        None => None,
    };
    let consent = kind == ScreenAnnotationKind::Consent;
    if consent != annotation_id.is_none() || (consent && sender != target_user_id) {
        return None;
    }
    if frame.points.len() > MAX_ANNOTATION_POINTS * 2
        || !frame.points.iter().all(|v| (0.0..=1.0).contains(v))
        || !points_fit_kind(kind, frame.points.len())
    {
        return None;
    }
    let aspect = frame.aspect.filter(|a| ASPECT_RANGE.contains(a));
    let text = frame
        .text
        .filter(|t| kind == ScreenAnnotationKind::Note && !t.is_empty())
        .map(|t| t.chars().take(MAX_ANNOTATION_TEXT_CHARS).collect());
    Some(ScreenAnnotationEvent {
        channel_id,
        user_id: sender,
        target_user_id,
        kind,
        annotation_id,
        points: frame.points,
        color: valid_preview_color(frame.color),
        text,
        ended: frame.ended,
        allowed: consent && frame.allowed,
        aspect: if consent { aspect } else { None },
    })
}

fn points_fit_kind(kind: ScreenAnnotationKind, len: usize) -> bool {
    match kind {
        ScreenAnnotationKind::Consent => len == 0,
        ScreenAnnotationKind::Stroke => len.is_multiple_of(2),
        ScreenAnnotationKind::Shape => len == 4 || len == 0,
        ScreenAnnotationKind::Note => len == 2,
    }
}

#[cfg(test)]
mod screen_annotation_tests {
    use super::*;

    fn frame(kind: &str) -> ScreenAnnotationFrame {
        ScreenAnnotationFrame {
            channel_id: uuid::Uuid::now_v7().to_string(),
            target_user_id: uuid::Uuid::now_v7().to_string(),
            kind: kind.to_owned(),
            annotation_id: Some(uuid::Uuid::now_v7().to_string()),
            points: vec![0.1, 0.2],
            color: Some("red".to_owned()),
            text: None,
            ended: false,
            allowed: false,
            aspect: None,
        }
    }

    fn sender() -> UserId {
        UserId(uuid::Uuid::now_v7())
    }

    #[test]
    fn a_stroke_inside_the_unit_square_relays() {
        let event = checked_annotation(sender(), frame("stroke")).unwrap();
        assert_eq!(event.points, vec![0.1, 0.2]);
        assert!(!event.allowed);
    }

    #[test]
    fn a_point_outside_the_unit_square_is_refused() {
        let mut f = frame("stroke");
        f.points = vec![0.5, 1.5];
        assert!(checked_annotation(sender(), f).is_none());
    }

    #[test]
    fn consent_is_only_believed_from_the_sharer_it_speaks_for() {
        let who = sender();
        let mut f = frame("consent");
        f.annotation_id = None;
        f.points = vec![];
        f.allowed = true;
        f.aspect = Some(1.78);
        let impostor = checked_annotation(sender(), clone_frame(&f));
        assert!(impostor.is_none());
        f.target_user_id = who.to_string();
        let event = checked_annotation(who, f).unwrap();
        assert!(event.allowed);
        assert_eq!(event.aspect, Some(1.78));
    }

    #[test]
    fn a_note_needs_exactly_one_corner_and_its_text_is_capped() {
        let mut f = frame("note");
        f.text = Some("x".repeat(500));
        let event = checked_annotation(sender(), f).unwrap();
        assert_eq!(
            event.text.unwrap().chars().count(),
            MAX_ANNOTATION_TEXT_CHARS
        );
        let mut two = frame("note");
        two.points = vec![0.1, 0.2, 0.3, 0.4];
        assert!(checked_annotation(sender(), two).is_none());
    }

    #[test]
    fn too_many_points_are_refused() {
        let mut f = frame("stroke");
        f.points = vec![0.5; MAX_ANNOTATION_POINTS * 2 + 2];
        assert!(checked_annotation(sender(), f).is_none());
    }

    #[test]
    fn a_stroke_must_carry_an_annotation_id_and_a_consent_must_not() {
        let mut f = frame("stroke");
        f.annotation_id = None;
        assert!(checked_annotation(sender(), f).is_none());
        assert!(checked_annotation(sender(), frame("consent")).is_none());
    }

    fn clone_frame(f: &ScreenAnnotationFrame) -> ScreenAnnotationFrame {
        ScreenAnnotationFrame {
            channel_id: f.channel_id.clone(),
            target_user_id: f.target_user_id.clone(),
            kind: f.kind.clone(),
            annotation_id: f.annotation_id.clone(),
            points: f.points.clone(),
            color: f.color.clone(),
            text: f.text.clone(),
            ended: f.ended,
            allowed: f.allowed,
            aspect: f.aspect,
        }
    }
}
