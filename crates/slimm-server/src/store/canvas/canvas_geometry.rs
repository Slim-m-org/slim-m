// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
//! The bounded world's dimensions and the pure geometry checks over them,
//! split out of `canvas.rs` so those checks have a home to be unit-tested in
//! and the query-and-write file stays under its line budget. No database or
//! `Store` here: everything is a plain function of its arguments.

use crate::ids::ChannelId;

/// Half-width of the bounded world. The canvas is large but finite (owner
/// decision), and an object outside it could never be reached by panning.
pub const WORLD_LIMIT: f64 = 5_000_000.0;

/// The board's edges in world units, the server twin of `canvasBoard` in
/// `canvas_board.dart` (decision 0080); `board_matches_the_client_constants`
/// pins the two together.
pub const BOARD_MIN_X: f64 = -960.0;
pub const BOARD_MIN_Y: f64 = -540.0;
pub const BOARD_MAX_X: f64 = 2_880.0;
pub const BOARD_MAX_Y: f64 = 1_620.0;

/// What a write that leaves the board answers with; names [`BOARD_MIN_X`] to [`BOARD_MAX_Y`].
pub const OUTSIDE_BOARD: &str = "object must lie inside the board (-960,-540)-(2880,1620)";

/// What an edge whose free end leaves the board answers with.
pub const EDGE_END_OUTSIDE_BOARD: &str =
    "a free edge end must lie inside the board (-960,-540)-(2880,1620)";

/// The slack the client's own containment check allows (`_trackOutside`), so
/// float noise in a clamped box never counts as outside.
const BOARD_SLACK: f64 = 0.5;

/// Longest side one object may declare.
///
/// The world alone is not a bound worth having here: a single object legally
/// spanning it is written into every cell of the client's uniform grid, which
/// at a 1024px cell is 95 million buckets and hangs whoever opens the canvas
/// next. Nothing this slice can draw is wider than a few screens, and the
/// ceiling has to be on the server or the row is still there for every other
/// client build.
pub const MAX_OBJECT_EXTENT: f64 = 8_192.0;

/// The default cap on live objects one channel's canvas may hold, applied
/// when a deployment has not set its own (see `Store::canvas_object_cap`).
///
/// A canvas is a broadly-granted unbounded write with no removal path in this
/// slice, which is the one combination that cannot be walked back, so the
/// ceiling is refused inside the same transaction that counts - the shape
/// `MAX_PINS_PER_CHANNEL` already uses. It also keeps a whole-canvas read
/// inside what the viewport limit can answer. This value is the DEFAULT in
/// `0052_canvas_object_cap.sql`; a test pins the two together.
pub const MAX_OBJECTS_PER_CHANNEL: i64 = 20_000;

/// The range a deployment may set its per-channel canvas cap to
/// (`Store::set_canvas_object_cap`). The floor keeps a canvas usable; the
/// ceiling keeps one admin from raising the cap high enough that a full canvas
/// tanks every client's memory and paint, which is the very load this setting
/// exists to bound. Enforced in Rust, not as a CHECK, so the range can move
/// without a migration - the same split `MAX_MESSAGE_RETENTION_DAYS` uses.
pub const MIN_CANVAS_OBJECT_CAP: i64 = 100;
pub const MAX_CANVAS_OBJECT_CAP: i64 = 100_000;

/// A 24-bit discriminant of a channel id, stored on every object and used as
/// the R-Tree's third dimension. Drawn from the UUIDv7's random tail, not its
/// timestamp prefix, which channels created in the same millisecond share.
pub(crate) fn channel_key(channel_id: ChannelId) -> i64 {
    let bytes = channel_id.0.as_bytes();
    i64::from(bytes[13]) << 16 | i64::from(bytes[14]) << 8 | i64::from(bytes[15])
}

/// Whether a bounding box is finite, non-negative, within
/// [`MAX_OBJECT_EXTENT`] and inside the bounded world. Shared with
/// `canvas_ops_write`'s `move`, which is the same shape check a placement
/// already makes.
pub(crate) fn valid_bounds(x: f64, y: f64, w: f64, h: f64) -> bool {
    [x, y, w, h].iter().all(|v| v.is_finite())
        && w >= 0.0
        && h >= 0.0
        && w <= MAX_OBJECT_EXTENT
        && h <= MAX_OBJECT_EXTENT
        && x >= -WORLD_LIMIT
        && y >= -WORLD_LIMIT
        && x + w <= WORLD_LIMIT
        && y + h <= WORLD_LIMIT
}

/// Whether a box lies wholly inside the board, with the client's half-unit slack.
pub(crate) fn board_holds(x: f64, y: f64, w: f64, h: f64) -> bool {
    x >= BOARD_MIN_X - BOARD_SLACK
        && y >= BOARD_MIN_Y - BOARD_SLACK
        && x + w <= BOARD_MAX_X + BOARD_SLACK
        && y + h <= BOARD_MAX_Y + BOARD_SLACK
}

/// Whether a point lies on the board, with the same slack as [`board_holds`].
pub(crate) fn board_holds_point(x: f64, y: f64) -> bool {
    board_holds(x, y, 0.0, 0.0)
}

/// Whether one axis of a box, as `(start, length)`, may go from `from` to `to` against `[lo, hi]`.
///
/// Inside is always fine. A length no board can hold may sit where the client leaves it, on the
/// near edge, or anywhere not further from the board's middle than it already is.
fn axis_respects(from: (f64, f64), to: (f64, f64), (lo, hi): (f64, f64)) -> bool {
    let inside =
        |(start, len): (f64, f64)| start >= lo - BOARD_SLACK && start + len <= hi + BOARD_SLACK;
    if inside(to) {
        return true;
    }
    let oversized = to.1 > hi - lo + 2.0 * BOARD_SLACK;
    let middle_off = |(start, len): (f64, f64)| (start + len / 2.0 - (lo + hi) / 2.0).abs();
    oversized && ((to.0 - lo).abs() <= BOARD_SLACK || middle_off(to) <= middle_off(from))
}

/// Whether moving an object of `kind` from `from` to `to` respects the board.
///
/// A result inside the board always does, which is how "bring in" works for old content outside.
/// A stroke larger than the board on an axis can never be brought in, so on that axis it may move
/// only as `axis_respects` allows. Any other result outside is refused, except the unchanged box,
/// which changes nothing.
pub(crate) fn move_respects_board(
    kind: &str,
    from: (f64, f64, f64, f64),
    to: (f64, f64, f64, f64),
) -> bool {
    if board_holds(to.0, to.1, to.2, to.3) || from == to {
        return true;
    }
    kind == "stroke"
        && axis_respects((from.0, from.2), (to.0, to.2), (BOARD_MIN_X, BOARD_MAX_X))
        && axis_respects((from.1, from.3), (to.1, to.3), (BOARD_MIN_Y, BOARD_MAX_Y))
}

#[cfg(test)]
mod tests {
    use super::{
        BOARD_MAX_X, BOARD_MAX_Y, BOARD_MIN_X, BOARD_MIN_Y, EDGE_END_OUTSIDE_BOARD,
        MAX_OBJECT_EXTENT, OUTSIDE_BOARD, WORLD_LIMIT, board_holds, board_holds_point, channel_key,
        move_respects_board, valid_bounds,
    };
    use crate::ids::ChannelId;

    #[test]
    fn a_plain_box_inside_the_world_is_valid() {
        assert!(valid_bounds(0.0, 0.0, 100.0, 100.0));
        assert!(valid_bounds(-WORLD_LIMIT, -WORLD_LIMIT, 10.0, 10.0));
    }

    /// Non-finite coordinates are refused before any comparison, so a NaN or an
    /// infinity can never reach the database or the client's grid.
    #[test]
    fn non_finite_coordinates_are_refused() {
        assert!(!valid_bounds(f64::NAN, 0.0, 1.0, 1.0));
        assert!(!valid_bounds(0.0, f64::INFINITY, 1.0, 1.0));
        assert!(!valid_bounds(0.0, 0.0, f64::NAN, 1.0));
        assert!(!valid_bounds(0.0, 0.0, 1.0, f64::NEG_INFINITY));
    }

    #[test]
    fn a_negative_extent_is_refused() {
        assert!(!valid_bounds(0.0, 0.0, -1.0, 10.0));
        assert!(!valid_bounds(0.0, 0.0, 10.0, -1.0));
    }

    /// The extent ceiling is inclusive, so the exact maximum passes and a hair
    /// over it does not.
    #[test]
    fn an_over_size_object_is_refused_at_the_extent_ceiling() {
        assert!(valid_bounds(0.0, 0.0, MAX_OBJECT_EXTENT, MAX_OBJECT_EXTENT));
        assert!(!valid_bounds(0.0, 0.0, MAX_OBJECT_EXTENT + 1.0, 10.0));
        assert!(!valid_bounds(0.0, 0.0, 10.0, MAX_OBJECT_EXTENT + 1.0));
    }

    /// It is the far corner (`x + w`, `y + h`) that must fit, not the origin:
    /// a box whose origin is inside the world but whose width carries it past
    /// the edge is refused.
    #[test]
    fn a_box_whose_far_corner_leaves_the_world_is_refused() {
        assert!(valid_bounds(WORLD_LIMIT - 100.0, 0.0, 100.0, 10.0));
        assert!(!valid_bounds(WORLD_LIMIT - 100.0, 0.0, 101.0, 10.0));
        assert!(!valid_bounds(0.0, WORLD_LIMIT - 100.0, 10.0, 101.0));
        assert!(!valid_bounds(-WORLD_LIMIT - 1.0, 0.0, 10.0, 10.0));
    }

    /// The key is drawn from the id's last three bytes, so it is stable for a
    /// given channel and lands inside the 24 bits the R-Tree dimension holds.
    #[test]
    fn a_channel_key_is_stable_and_within_twenty_four_bits() {
        let id = ChannelId::generate();
        assert_eq!(channel_key(id), channel_key(id));
        assert!((0..=0xFF_FFFF).contains(&channel_key(id)));
    }

    #[test]
    fn the_refusal_text_names_the_board_constants() {
        let corners = format!("({BOARD_MIN_X},{BOARD_MIN_Y})-({BOARD_MAX_X},{BOARD_MAX_Y})");
        assert_eq!(
            OUTSIDE_BOARD,
            format!("object must lie inside the board {corners}")
        );
        assert_eq!(
            EDGE_END_OUTSIDE_BOARD,
            format!("a free edge end must lie inside the board {corners}")
        );
    }

    /// The board is the shared area grown to twice its size around its centre (decision 0080).
    #[test]
    fn the_board_is_the_shared_area_doubled() {
        assert_eq!(
            (BOARD_MAX_X - BOARD_MIN_X, BOARD_MAX_Y - BOARD_MIN_Y),
            (3840.0, 2160.0)
        );
        assert_eq!(
            (BOARD_MIN_X + BOARD_MAX_X, BOARD_MIN_Y + BOARD_MAX_Y),
            (1920.0, 1080.0)
        );
    }

    #[test]
    fn a_box_is_held_only_when_wholly_on_the_board() {
        assert!(board_holds(0.0, 0.0, 100.0, 100.0));
        assert!(board_holds(BOARD_MIN_X, BOARD_MIN_Y, 3840.0, 2160.0));
        assert!(board_holds(BOARD_MIN_X - 0.5, 0.0, 10.0, 10.0));
        assert!(!board_holds(BOARD_MIN_X - 0.6, 0.0, 10.0, 10.0));
        assert!(!board_holds(2800.0, 0.0, 100.0, 10.0));
        assert!(!board_holds(0.0, 1600.0, 10.0, 30.0));
        assert!(board_holds_point(BOARD_MAX_X, BOARD_MAX_Y));
        assert!(!board_holds_point(BOARD_MAX_X + 1.0, 0.0));
    }

    #[test]
    fn a_move_onto_the_board_or_toward_it_is_allowed_only_when_it_lands_inside() {
        let outside = (5000.0, 0.0, 100.0, 100.0);
        assert!(move_respects_board(
            "shape",
            outside,
            (0.0, 0.0, 100.0, 100.0)
        ));
        assert!(!move_respects_board(
            "shape",
            outside,
            (4000.0, 0.0, 100.0, 100.0)
        ));
        assert!(!move_respects_board(
            "shape",
            (0.0, 0.0, 10.0, 10.0),
            outside
        ));
        assert!(move_respects_board("shape", outside, outside));
    }

    #[test]
    fn an_oversized_stroke_may_move_toward_the_middle_or_to_the_near_edge_only() {
        let huge = (-500.0, 0.0, 6000.0, 100.0);
        assert!(move_respects_board(
            "stroke",
            huge,
            (-1500.0, 0.0, 6000.0, 100.0)
        ));
        assert!(move_respects_board(
            "stroke",
            huge,
            (BOARD_MIN_X, 0.0, 6000.0, 100.0)
        ));
        assert!(!move_respects_board(
            "stroke",
            huge,
            (0.0, 0.0, 6000.0, 100.0)
        ));
        assert!(!move_respects_board(
            "stroke",
            huge,
            (-500.0, 5000.0, 6000.0, 100.0)
        ));
        assert!(!move_respects_board(
            "shape",
            huge,
            (-1500.0, 0.0, 6000.0, 100.0)
        ));
        assert!(!move_respects_board(
            "stroke",
            (0.0, 0.0, 10.0, 10.0),
            (5000.0, 0.0, 10.0, 10.0)
        ));
    }
}
