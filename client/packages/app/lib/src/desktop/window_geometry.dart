// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The window's own saved shape, and the arithmetic that decides whether a
/// saved position is still safe to apply.
///
/// Everything here is plain Dart with no platform channel behind it, per
/// decision 0012's own rule: geometry-clamp math is one of the four things
/// that record names as fully automatable with no display involved.
library;

import 'dart:math' as math;

/// The desktop splash window's own fixed footprint - the canonical value
/// behind `DesktopWindowShell.splashWindowSize`, defined here rather than
/// there because this file is deliberately platform-channel-free per
/// decision 0012's own rule, and `DesktopWindowShell` already imports this
/// file, so the reverse import would be a cycle. See [looksLikeSplashSize].
const kSplashWindowSize = WindowSize(width: 380, height: 460);

/// The tallest a native Linux title bar could still be adding on top of
/// [kSplashWindowSize] at the instant a stray write landed, before
/// `DesktopWindowShell.lockSplashChrome` hid it: decision 0012's own
/// title-bar section measures "a native GNOME GTK header bar runs roughly
/// 46-48 logical pixels." The regression this constant exists to catch
/// produced exactly that: a saved height of 508, which is 460 plus 48.
const _splashTitleBarMargin = 48;

/// True only if [size] could never be a real desktop window a user resized
/// to through this app's own UI - both dimensions have to sit at or below
/// the splash's own footprint (width) or that footprint plus a lingering
/// native title bar (height) for this to trip, so an oddly-shaped but
/// otherwise ordinary window (very narrow and tall, or very short and wide)
/// does not get caught by one axis alone. [DesktopWindowController] no
/// longer ever writes a splash-sized geometry (see its
/// `geometryPersistenceEnabled` gate), so on any build carrying that fix a
/// size this small can only be leftover corruption from a build that
/// shipped without it - see [healSplashCorruption].
bool looksLikeSplashSize(WindowSize size) =>
    size.width <= kSplashWindowSize.width &&
    size.height <= kSplashWindowSize.height + _splashTitleBarMargin;

/// [geometry] as read from disk, replaced with [WindowGeometry.fallback]
/// wholesale - not patched field by field - if its [WindowGeometry.windowedSize]
/// [looksLikeSplashSize]. A full reset rather than a narrower fix: a
/// corrupted [WindowGeometry.position] carries the same implausible
/// dimensions in its own width/height (the regression's own sample has
/// position 45,45,380,508 alongside a windowedSize of 380x508), and a
/// [WindowRunState.maximized] carried alongside a corrupted size reflects a
/// later, separately-legitimate maximize event that only ever preserves
/// whatever windowed size preceded it - so nothing else in the record can be
/// trusted once its size is this implausible. This is the read-time half of
/// the splash-corruption fix; [DesktopWindowController.enableGeometryPersistence]
/// is the write-time half that stops new corruption from ever landing.
WindowGeometry healSplashCorruption(WindowGeometry geometry) =>
    looksLikeSplashSize(geometry.windowedSize)
    ? WindowGeometry.fallback
    : geometry;

/// Which of the three states the window was actually in, since only one of
/// them - [windowed] - is a rectangle. Maximized and full-screen both keep
/// [WindowGeometry.windowedSize] around as "what to return to", the same way
/// a browser remembers its own un-maximized bounds.
enum WindowRunState { windowed, maximized, fullscreen }

/// A plain width/height pair. Kept distinct from [WindowRect] because a
/// window's size is meaningful with no position at all - the one thing this
/// record says every platform can persist, where position is Wayland-blind.
class WindowSize {
  const WindowSize({required this.width, required this.height});

  factory WindowSize.fromJson(Map<String, dynamic> json) => WindowSize(
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
  );

  final double width;
  final double height;

  Map<String, dynamic> toJson() => {'width': width, 'height': height};

  @override
  bool operator ==(Object other) =>
      other is WindowSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// A window's on-screen rectangle, top-left origin. Only ever set where the
/// platform lets an app read or write its own position; see
/// [WindowGeometry.position]'s own doc for which platforms that is.
class WindowRect {
  const WindowRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory WindowRect.fromJson(Map<String, dynamic> json) => WindowRect(
    x: (json['x'] as num).toDouble(),
    y: (json['y'] as num).toDouble(),
    width: (json['width'] as num).toDouble(),
    height: (json['height'] as num).toDouble(),
  );

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  /// Whether this rectangle shares any area with [display]. A rectangle with
  /// zero or negative overlap on either axis is entirely off that display.
  bool overlaps(DisplayArea display) {
    final overlapsX = x < display.x + display.width && x + width > display.x;
    final overlapsY = y < display.y + display.height && y + height > display.y;
    return overlapsX && overlapsY;
  }
}

/// One attached display's work area, in the same coordinate space a saved
/// [WindowRect] was recorded in.
class DisplayArea {
  const DisplayArea({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;
}

/// The whole persisted answer: a size (always), a position (only where the
/// platform can act on one), and which of the three run states it was in.
class WindowGeometry {
  const WindowGeometry({
    required this.windowedSize,
    this.position,
    this.runState = WindowRunState.windowed,
  });

  /// The existing native default, kept rather than invented anew: decision
  /// 0012 names this as the cold-start fallback with nothing saved yet.
  static const fallback = WindowGeometry(
    windowedSize: WindowSize(width: 1280, height: 720),
  );

  /// The smallest a desktop window may be dragged to.
  ///
  /// Above `kCompactWidth` on purpose, and not by a hair. Below that width
  /// the shell is the phone layout - one pane, no member list, sheets where
  /// dialogs belong - and a desktop window that reaches it reads as the app
  /// having broken rather than adapted. Nothing stopped it before: the
  /// layout rule is width-not-platform and correct, but no floor kept a
  /// desktop window on the right side of it, so a window a person thought
  /// was ordinary could sit at 580 logical pixels on a scaled display and
  /// render as a phone.
  ///
  /// 800x600 leaves the rail its width and the transcript the rest, which is
  /// the narrowest arrangement that still reads as this app. The splash is
  /// deliberately smaller and is applied before this floor exists.
  static const minimumWindowSize = WindowSize(width: 800, height: 600);

  /// The last known windowed rectangle's size. Kept even while [runState] is
  /// [WindowRunState.maximized] or [WindowRunState.fullscreen], so returning
  /// to windowed has something real to restore to rather than a guess.
  final WindowSize windowedSize;

  /// Null on a platform that cannot act on its own position (Wayland, by
  /// design - see the decision record), or on a fresh install with nothing
  /// saved yet. Never null on a platform where position is real and has been
  /// recorded at least once.
  final WindowRect? position;

  final WindowRunState runState;

  factory WindowGeometry.fromJson(Map<String, dynamic> json) {
    final rawPosition = json['position'];
    return WindowGeometry(
      windowedSize: WindowSize.fromJson(
        json['windowedSize'] as Map<String, dynamic>,
      ),
      position: rawPosition == null
          ? null
          : WindowRect.fromJson(rawPosition as Map<String, dynamic>),
      runState: WindowRunState.values.firstWhere(
        (state) => state.name == json['runState'],
        orElse: () => WindowRunState.windowed,
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'windowedSize': windowedSize.toJson(),
    'position': position?.toJson(),
    'runState': runState.name,
  };

  WindowGeometry copyWith({
    WindowSize? windowedSize,
    WindowRect? position,
    bool clearPosition = false,
    WindowRunState? runState,
  }) => WindowGeometry(
    windowedSize: windowedSize ?? this.windowedSize,
    position: clearPosition ? null : (position ?? this.position),
    runState: runState ?? this.runState,
  );
}

/// A saved [geometry] validated against the displays actually attached right
/// now: a position that no longer lands on anything is dropped, and a size
/// larger than the biggest display is capped to it (never below
/// [WindowGeometry.minimumWindowSize]).
///
/// [displays] empty is treated the same as "nothing intersects" for the
/// position: one this call cannot confirm is safe is not applied, the same
/// fail-closed choice the decision record makes for the tray-availability
/// probe. The size has nothing to be capped against then, so it is left alone.
/// [geometry] with no [WindowGeometry.position] keeps passing the position
/// through - there was nothing to validate, which is the ordinary Wayland case.
WindowGeometry clampToAttachedDisplays(
  WindowGeometry geometry,
  List<DisplayArea> displays,
) {
  final sized = _capSizeToDisplays(geometry, displays);
  final position = sized.position;
  if (position == null) return sized;
  final stillAttached = displays.any(position.overlaps);
  return stillAttached ? sized : sized.copyWith(clearPosition: true);
}

WindowGeometry _capSizeToDisplays(
  WindowGeometry geometry,
  List<DisplayArea> displays,
) {
  if (displays.isEmpty) return geometry;
  final min = WindowGeometry.minimumWindowSize;
  final maxWidth = displays.map((d) => d.width).reduce(math.max);
  final maxHeight = displays.map((d) => d.height).reduce(math.max);
  final size = geometry.windowedSize;
  final width = math.max(math.min(size.width, maxWidth), min.width);
  final height = math.max(math.min(size.height, maxHeight), min.height);
  if (width == size.width && height == size.height) return geometry;
  return geometry.copyWith(
    windowedSize: WindowSize(width: width, height: height),
  );
}

/// A [geometry] whose [WindowGeometry.windowedSize] is never below
/// [WindowGeometry.minimumWindowSize].
///
/// The OS minimum ([DesktopWindowPort.setMinimumSize]) is meant to keep a
/// window off the phone-layout side of `kCompactWidth`, but it is not honored
/// everywhere - notably a window_manager running over XWayland/Wayland, where
/// a saved size below the floor (from an older build, or a compositor that let
/// the drag through) is then restored verbatim and the desktop opens compact
/// "again". Clamping the size the app itself sets closes that path regardless
/// of whether the OS enforces its own minimum. Only ever enlarges an
/// undersized window; a size already at or above the floor passes through.
WindowGeometry clampSizeToMinimum(WindowGeometry geometry) {
  final min = WindowGeometry.minimumWindowSize;
  final size = geometry.windowedSize;
  if (size.width >= min.width && size.height >= min.height) return geometry;
  return geometry.copyWith(
    windowedSize: WindowSize(
      width: math.max(size.width, min.width),
      height: math.max(size.height, min.height),
    ),
  );
}
