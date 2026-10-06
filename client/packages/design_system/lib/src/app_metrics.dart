// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Spacing, radii, control sizes and the two shadows this system has.
///
/// Everything here is a closed set. The point of naming them is that a
/// contributor picks from a list instead of inventing a value, so adding a step
/// costs more than it looks: it is one more thing for the next person to choose
/// wrongly between.
library;

import 'package:flutter/widgets.dart';

/// The 4dp spacing grid, named by value.
abstract final class AppSpacing {
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s32 = 32;
  static const double s40 = 40;
  static const double s48 = 48;
  static const double s64 = 64;
}

/// The three vertical insets that deliberately sit off the 4dp grid.
///
/// A heading is not a row. It wants more air above it than below, so that it
/// reads as belonging to what follows rather than floating between two groups,
/// and the 4dp grid's nearest pair - 12 above, 8 below - is both too loose and
/// too even to say that. The rail, the member pane and the transcript all
/// settled on the same answer independently, which is what makes this a rhythm
/// worth naming rather than drift worth re-gridding: 10 above a heading in a
/// side pane, 14 above a divider band in the transcript, 6 below either.
///
/// Named rather than re-gridded on purpose. Moving these onto the grid shifts
/// real pixels on the two surfaces a person looks at most, and that is a design
/// call rather than a hygiene one; naming them costs nothing and stops the next
/// contributor reading them as four unrelated magic numbers.
///
/// A value used at one site is not a token. Anything smaller or more local than
/// these - a 2dp optical nudge under a line of text, an indent aligning to a
/// particular row's icon column - stays a named constant in the file that owns
/// it, where the thing it aligns to can be named too.
abstract final class AppRhythm {
  /// Above a heading or a grouped block in a side pane.
  static const double headingTop = 10;

  /// Below a heading or a divider, before what it introduces.
  static const double headingBottom = 6;

  /// Above a divider band in the transcript, which carries more weight than a
  /// side pane's heading and needs the extra air to separate two days or the
  /// read from the unread.
  static const double dividerTop = 14;
}

/// Corner radii; elevation is border-first, so shadows are rare.
///
/// Three steps plus full. A 4dp and a 6dp corner are indistinguishable under a
/// 1px hairline, so the extra step bought nothing except one more judgement
/// call per contributor. [window] is reserved for floating canvas objects.
abstract final class AppRadii {
  static const double control = 6;
  static const double card = 10;
  static const double window = 16;
  static const double full = 999;
}

/// The width below which one pane fits at a time and a finger, not a pointer,
/// is the likely input.
///
/// Named here rather than in the app because `AppTouchTargets` falls back to
/// it; the app's `LayoutClass.compact` reads this same value, so the layout
/// and the hit targets cannot drift apart.
const double kCompactWidth = 600;

/// Minimum interactive sizes.
///
/// [rowPointer] and [rowTouch] are the same row at two input classes, not two
/// designs. A compact layout raises rows to the touch value; nothing else about
/// the row changes, because a row that also shrinks its type at touch size is
/// harder to hit *and* harder to read.
abstract final class AppSizes {
  static const double rowPointer = 30;
  static const double rowTouch = 44;

  /// A touch-density menu row, a step above [rowTouch]. A menu is a dense
  /// column of discrete choices with no gaps between them, so the tap target
  /// is grown past the 44 minimum to widen the margin for a mis-tap onto the
  /// neighbouring row. Its own named step so the value stops being a literal
  /// nobody could place on the scale.
  static const double rowTouchMenu = 48;

  /// The conversation pane's side gutter: the header, every message row and
  /// the composer share it, or their left and right edges visibly disagree.
  ///
  /// Tighter at touch density because the avatar column already eats a narrow
  /// measure on a phone. Three files each hardcoded their own number before
  /// this existed, and had drifted to 16, 20 and 20.
  static const double paneGutter = 20;
  static const double paneGutterCompact = 10;

  static const double controlSm = 26;
  static const double controlMd = 34;
  static const double controlLg = 38;

  static const double icon16 = 16;
  static const double icon20 = 20;
  static const double icon24 = 24;

  /// A step between [icon24] and [icon32], previously reinvented three ways
  /// with no name of its own: `icon20 + 8` at two sheet call sites, and an
  /// unnamed literal for `AppIconButtonSize.md`'s diameter.
  static const double icon28 = 28;
  static const double icon32 = 32;

  /// The height of every pane's header bar - the conversation header, the
  /// rail's own, the member pane's, a DM call's - so the bars across the shell
  /// meet on one line. Five files each carried the literal before this existed.
  static const double headerBar = 52;
}

/// The diameters a person's picture is drawn at. Every avatar in the app takes
/// one of these, so the same size looks the same on every surface.
///
/// Below [s24] there is no room for a presence dot beside two initials, so no
/// surface smaller than that carries one.
abstract final class AppAvatarSize {
  /// A voice participant in a rail row; no dot.
  static const double s16 = 16;
  static const double s20 = 20;

  /// The smallest size that carries a presence dot: a DM row.
  static const double s24 = 24;

  /// A member row, the rail footer, a pinned or saved message.
  static const double s28 = 28;
  static const double s32 = 32;

  /// A message row's author, and the default.
  static const double s36 = 36;

  /// The member card.
  static const double s44 = 44;

  /// A canvas presence bubble.
  static const double s56 = 56;

  /// The settings picker.
  static const double s72 = 72;

  /// An incoming-call overlay.
  static const double s96 = 96;

  /// The largest step from [s32] up that fits in [available], for a tile whose
  /// room varies: the picture then snaps to a size every other surface uses.
  static double largestWithin(double available) {
    const steps = [s32, s36, s44, s56, s72, s96];
    return steps.lastWhere((step) => step <= available, orElse: () => s32);
  }
}

/// The shadows, for the few things that genuinely float.
///
/// Elevation is otherwise carried entirely by a 1px hairline. A shadow here is
/// a statement that something is above the plane rather than part of it, which
/// is true of a menu, a dragged canvas object, and a live media tile.
abstract final class AppShadows {
  static const List<BoxShadow> menu = [
    BoxShadow(
      color: Color(0x6B000000),
      blurRadius: 40,
      offset: Offset(0, 16),
    ),
  ];

  static const List<BoxShadow> float = [
    BoxShadow(
      color: Color(0x85000000),
      blurRadius: 64,
      offset: Offset(0, 24),
    ),
  ];

  /// A live camera or screen tile resting on the canvas (and the toast and call
  /// mini-player, which also rest above the plane), which sits over the
  /// grid all the time rather than only while a drag lifts it. [float]'s deep,
  /// far-offset cast reads as a hard dark band under a permanent tile,
  /// especially against the dark-theme canvas; this is the same lift at a
  /// fraction of the weight - a resting elevation, not a picked-up one.
  static const List<BoxShadow> canvasTile = [
    BoxShadow(
      color: Color(0x40000000),
      blurRadius: 24,
      offset: Offset(0, 6),
    ),
  ];
}

/// Vertical rhythm, which is the only thing the density setting moves.
///
/// Type sizes, avatar sizes and touch targets deliberately do not respond to
/// it. Someone choosing "compact" wants more messages on screen, not smaller
/// text, and conflating the two produces a mode nobody can read.
/// [groupWindow] is how long one author keeps writing into the same block
/// before the next message starts a fresh one with their picture and name
/// above it again. It was minutes long, which read as one wall of text with
/// nobody's name on it whenever a conversation was slow (owner, 2026-08-13:
/// "even if there is a minute between messages, we should paste the users
/// profile picture instead of extending the text wall with no name on left
/// side"). A minute is the floor rather than a scale point: below it a burst
/// of someone typing three lines in a row splits into three headed blocks,
/// which is noisier than the problem being fixed - so normal and spacious
/// share it, and only compact still groups for longer.
enum AppDensity {
  compact(rowGap: 4, groupedRowGap: 1, groupWindow: Duration(minutes: 2)),
  normal(rowGap: 8, groupedRowGap: 2, groupWindow: Duration(minutes: 1)),
  spacious(rowGap: 12, groupedRowGap: 4, groupWindow: Duration(minutes: 1));

  const AppDensity({
    required this.rowGap,
    required this.groupedRowGap,
    required this.groupWindow,
  });

  /// Space above a message that starts a new group: a different author, or the
  /// same author past the [groupWindow]. This is the separation between one
  /// person's turn and the next, so it stays generous.
  final double rowGap;

  /// Space above a continuation of the same group. Much tighter than
  /// [rowGap]: a run of one person's messages should read as one block, not a
  /// ladder of evenly-spaced lines, which is what a uniform gap produced.
  final double groupedRowGap;

  /// How long after a message the same author's next one still counts as part
  /// of the same group and drops its avatar and header.
  final Duration groupWindow;
}

/// How wide a message column is allowed to get.
///
/// Line length, not layout: 15sp at 1.45 stops being comfortable to read well
/// before a wide monitor runs out of room.
const double kMessageColumnMax = 760;
