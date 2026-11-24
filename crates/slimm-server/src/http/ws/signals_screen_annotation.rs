// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The screen-annotation signal: viewers' marks over a shared screen, and the sharer's consent for them.

use std::sync::Arc;

use tokio::sync::mpsc;

use super::canvas_gate::{Frame, may_relay};
use super::permission_cache::PermissionCache;
use super::signals_canvas::valid_preview_color;
use crate::hidden_chars::{draws_nothing, is_hidden_char};
use crate::http::AppState;
use crate::hub::{CanvasEvent, Event, Hub, ScreenAnnotationEvent, ScreenAnnotationKind};
use crate::ids::{ChannelId, UserId};
use crate::ratelimit::Class;
use crate::store::SessionContext;
use crate::voice::VoiceService;

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
    pub(super) stamps: bool,
}

/// Most coordinate pairs one annotation frame may carry.
const MAX_ANNOTATION_POINTS: usize = 24;

/// Longest sticky-note text relayed, in characters.
const MAX_ANNOTATION_TEXT_CHARS: usize = 80;

/// Widest and narrowest screen shape a consent frame may claim.
const ASPECT_RANGE: std::ops::RangeInclusive<f64> = 0.2..=10.0;

/// Relays a screen annotation, or a sharer's consent, to the people in a channel's call (decision 0096).
///
/// Gated like ink and charged against the stroke-preview budget here, where a consent is also
/// remembered for the stamp route; the roster read and the publish run on `relay`.
pub(super) async fn handle_canvas_screen_annotation(
    state: &AppState,
    ctx: &SessionContext,
    cache: &mut PermissionCache,
    relay: &mut AnnotationRelay,
    frame: ScreenAnnotationFrame,
    frame_bytes: usize,
) {
    let Some(event) = checked_annotation(ctx.user_id, frame) else {
        return;
    };
    let key = format!("u:{}", ctx.user_id);
    if !state
        .limiter
        .check_weighted(Class::CanvasStrokePreview, &key, frame_bytes as f64)
    {
        return;
    }
    state.hub.presence().touch(ctx.user_id);
    if !may_relay(
        &state.store,
        &state.hub,
        ctx,
        cache,
        event.channel_id,
        Frame::Ink,
    )
    .await
    {
        return;
    }
    if event.kind == ScreenAnnotationKind::Consent {
        let said = (event.allowed, event.stamps);
        let now = std::time::Instant::now();
        state
            .hub
            .screen_consent()
            .record(event.channel_id, event.user_id, said, now);
    }
    relay.send(state, event);
}

/// Frames one connection may have waiting on a roster read; past it a frame is dropped, as a lagging ephemeral one is.
const RELAY_QUEUE: usize = 32;

/// One connection's annotation publisher: a task started by its first annotation and ended when the
/// connection drops this, so the socket never waits on the SFU and the frames keep their order.
#[derive(Default)]
pub(super) struct AnnotationRelay {
    queue: Option<mpsc::Sender<ScreenAnnotationEvent>>,
}

impl AnnotationRelay {
    fn send(&mut self, state: &AppState, event: ScreenAnnotationEvent) {
        let queue = self
            .queue
            .get_or_insert_with(|| spawn_relay(state.voice.clone(), state.hub.clone()));
        let _ = queue.try_send(event);
    }
}

fn spawn_relay(voice: VoiceService, hub: Hub) -> mpsc::Sender<ScreenAnnotationEvent> {
    let (queue, mut waiting) = mpsc::channel(RELAY_QUEUE);
    tokio::spawn(async move {
        while let Some(mut event) = waiting.recv().await {
            let Some(audience) = call_audience(&voice, &event).await else {
                continue;
            };
            event.audience = audience;
            hub.publish(Event::Canvas(CanvasEvent::ScreenAnnotation(Arc::new(
                event,
            ))));
        }
    });
    queue
}

/// Everyone in the channel's call, from the shared roster the soundboard trusts; none when a mark's sender or sharer is not in it.
async fn call_audience(voice: &VoiceService, event: &ScreenAnnotationEvent) -> Option<Vec<UserId>> {
    let mut audience: Vec<UserId> = voice
        .list_participants_shared(event.channel_id)
        .await
        .ok()?
        .into_iter()
        .map(|p| p.user_id)
        .collect();
    audience.sort_unstable();
    audience.dedup();
    // Consent needs no seat, so a withdrawal sent while leaving the call still lands.
    let seated = event.kind == ScreenAnnotationKind::Consent
        || [event.user_id, event.target_user_id]
            .iter()
            .all(|user| audience.binary_search(user).is_ok());
    (seated && !audience.is_empty()).then_some(audience)
}

/// The relayed event for a well-formed frame from `sender`, or none.
fn checked_annotation(
    sender: UserId,
    frame: ScreenAnnotationFrame,
) -> Option<ScreenAnnotationEvent> {
    let channel_id = ChannelId(uuid::Uuid::parse_str(&frame.channel_id).ok()?);
    let target_user_id = UserId(uuid::Uuid::parse_str(&frame.target_user_id).ok()?);
    let kind = ScreenAnnotationKind::parse(&frame.kind)?;
    if kind == ScreenAnnotationKind::Stamp {
        return None;
    }
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
        .map(|t| {
            t.chars()
                .take(MAX_ANNOTATION_TEXT_CHARS)
                .collect::<String>()
        });
    if text
        .as_deref()
        .is_some_and(|t| t.chars().any(is_hidden_char) || draws_nothing(t))
    {
        return None;
    }
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
        audience: Vec::new(),
        stamp: None,
        stamps: consent && frame.stamps,
    })
}

fn points_fit_kind(kind: ScreenAnnotationKind, len: usize) -> bool {
    match kind {
        ScreenAnnotationKind::Consent => len == 0,
        ScreenAnnotationKind::Stroke => len.is_multiple_of(2),
        ScreenAnnotationKind::Shape => len == 4 || len == 0,
        ScreenAnnotationKind::Note | ScreenAnnotationKind::Stamp => len == 2,
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
            stamps: false,
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
    fn a_note_with_hidden_or_blank_text_is_dropped() {
        for text in [
            "ab\u{202E}cd",
            "bell\u{7}",
            "zero\u{200B}width",
            "\u{3164}\u{3164}",
        ] {
            let mut f = frame("note");
            f.text = Some(text.to_owned());
            assert!(checked_annotation(sender(), f).is_none(), "{text:?}");
        }
        let mut f = frame("note");
        f.text = Some("look here".to_owned());
        assert!(checked_annotation(sender(), f).is_some());
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
    fn a_stamp_never_enters_through_the_socket() {
        let mut f = frame("stamp");
        f.points = vec![0.5, 0.5];
        assert!(checked_annotation(sender(), f).is_none());
    }

    #[test]
    fn the_stamps_flag_survives_only_on_consent() {
        let who = sender();
        let mut consent = frame("consent");
        consent.annotation_id = None;
        consent.points = vec![];
        consent.target_user_id = who.to_string();
        consent.allowed = true;
        consent.stamps = true;
        assert!(checked_annotation(who, consent).unwrap().stamps);
        let mut stroke = frame("stroke");
        stroke.stamps = true;
        assert!(!checked_annotation(sender(), stroke).unwrap().stamps);
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
            stamps: f.stamps,
        }
    }
}
