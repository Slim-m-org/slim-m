// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The payload of [`super::CanvasEvent::ScreenAnnotation`], split out of `event.rs` to keep that file under its budget.

use crate::ids::{ChannelId, UserId};

/// What a [`ScreenAnnotationEvent`] says.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ScreenAnnotationKind {
    /// The sharer announcing whether viewers may draw on their screen.
    Consent,
    /// Freehand ink; `points` is a delta of normalised x/y pairs.
    Stroke,
    /// An ellipse; `points` is `[x0, y0, x1, y1]`, normalised.
    Shape,
    /// A sticky note; `points` is the normalised `[x, y]` of its corner.
    Note,
    /// An emoji or picture (decision 0121); `points` is its normalised centre.
    Stamp,
}

impl ScreenAnnotationKind {
    pub fn parse(raw: &str) -> Option<Self> {
        Some(match raw {
            "consent" => Self::Consent,
            "stroke" => Self::Stroke,
            "shape" => Self::Shape,
            "note" => Self::Note,
            // A stamp enters only through POST /channels/{id}/voice/screen-stamps.
            _ => return None,
        })
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Consent => "consent",
            Self::Stroke => "stroke",
            Self::Shape => "shape",
            Self::Note => "note",
            Self::Stamp => "stamp",
        }
    }
}

/// The body of [`crate::hub::CanvasEvent::ScreenAnnotation`].
#[derive(Debug, Clone)]
pub struct ScreenAnnotationEvent {
    pub channel_id: ChannelId,
    /// Who drew, or for a consent frame the sharer.
    pub user_id: UserId,
    /// Whose shared screen the annotation is over.
    pub target_user_id: UserId,
    pub kind: ScreenAnnotationKind,
    /// Keys one annotation across its frames; absent on a consent frame.
    pub annotation_id: Option<uuid::Uuid>,
    pub points: Vec<f64>,
    pub color: Option<String>,
    pub text: Option<String>,
    pub ended: bool,
    /// Consent frames only: whether viewers may draw right now.
    pub allowed: bool,
    /// Consent frames only: the shared screen's width over its height.
    pub aspect: Option<f64>,
    /// Who it is delivered to: the channel's call roster when it was relayed. Never on the wire.
    pub audience: Vec<UserId>,
    /// Stamp frames only: what was stamped and how big.
    pub stamp: Option<Stamp>,
    /// Consent frames only: whether the sharer's client can show stamps.
    pub stamps: bool,
}

/// A stamp's size and content, carried by a [`ScreenAnnotationKind::Stamp`] event.
#[derive(Debug, Clone, PartialEq)]
pub struct Stamp {
    /// The longest side, as a fraction of the shared screen's height.
    pub size: f64,
    pub content: StampContent,
}

/// What a stamp shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StampContent {
    /// A reaction key: one emoji, a `:shortcode:` or a custom emoji id.
    Emoji(String),
    /// An attachment, by hex id; `animated` is decided by the server from the stored row.
    Picture { attachment: String, animated: bool },
}
