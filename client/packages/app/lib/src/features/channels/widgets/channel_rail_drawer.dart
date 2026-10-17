// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The compact layout's edge-swipe route to the channel rail, and the second
/// half of that swipe: carrying it further opens the full-screen channel list.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../routing/routes.dart';
import 'channel_rail.dart';
import 'channel_rail_selection_marker.dart';

/// [ChannelRail] behind [Scaffold.drawer], for phone width.
///
/// This is the same widget the medium and expanded layouts dock beside the
/// conversation, here inside Flutter's own drawer machinery instead of a
/// hand-rolled one: the edge-drag gesture, the scrim, the open/close
/// animation and the modal semantics all come from [Scaffold] for free, the
/// way `HomeShell`'s member-pane `endDrawer` already gets them.
///
/// [ChannelRail]'s own row taps only navigate - they have no idea whether
/// they are docked or inside a drawer that ought to close over the choice.
/// Rather than thread a close callback through every row (three call sites
/// across two files), this widget watches the route's own answer to "which
/// channel is selected" and closes itself the moment that answer changes,
/// which is what selecting a channel here amounts to regardless of how the
/// route got there - a shortcut key cycling channels while this happens to
/// be open closes it exactly the same way a row tap does.
class CompactChannelRailDrawer extends StatefulWidget {
  const CompactChannelRailDrawer({required this.selectedChannelId, super.key});

  /// `selectedChannelId(context)`, read by [HomeShell] once and passed down
  /// so this widget never has to depend on the router directly.
  final String? selectedChannelId;

  @override
  State<CompactChannelRailDrawer> createState() =>
      _CompactChannelRailDrawerState();
}

/// Reachable only while a real `Drawer` is open, opening or closing - never
/// while fully dismissed - so there is no dismissed case to guard here.
/// [Scaffold.closeDrawer] itself reenters a build already under way (this
/// rebuild is the ancestor Scaffold's own), so the close waits a frame.
class _CompactChannelRailDrawerState extends State<CompactChannelRailDrawer> {
  /// Both survive this State's own disposal, since a `Drawer`'s subtree -
  /// this one included - is torn down on close. [_lastOffset] is kept
  /// current by [_trackOffset] on every scroll rather than read once at
  /// [dispose]: a `Scrollable` unmounts before its ancestors do, so by the
  /// time this State's own dispose runs, [_scrollController] has already
  /// detached and has nothing left to read.
  static double _lastOffset = 0;

  /// The channel that was selected the last time this closed - compared
  /// against [CompactChannelRailDrawer.selectedChannelId] on open to decide
  /// whether [_lastOffset] is even still relevant. A channel picked while
  /// this was closed (search, a notification) means the restored offset
  /// predates the selection, and reopening should reveal the new choice
  /// rather than reopen wherever browsing had scrolled to before it.
  static String? _lastSelectedId;

  /// Owned rather than the scroll view's own implicit one, so this can read
  /// and move its offset directly once the drawer's first frame lands.
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<SelectionMarkerLayerState> _markerLayerKey =
      GlobalKey<SelectionMarkerLayerState>();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_trackOffset);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOrReveal());
  }

  void _trackOffset() {
    if (_scrollController.hasClients) _lastOffset = _scrollController.offset;
  }

  @override
  void dispose() {
    _scrollController.removeListener(_trackOffset);
    _lastSelectedId = widget.selectedChannelId;
    _scrollController.dispose();
    super.dispose();
  }

  /// Re-applied across a few frames rather than attempted once: the channel
  /// list streams in from the local store, so the first frame or two lay out
  /// against a still-empty (or partial) child, reporting a `maxScrollExtent`
  /// smaller than the real one - [ScrollPosition.hasContentDimensions]
  /// itself turns true on that first, too-small layout, so it cannot gate
  /// this. Re-jumping every frame the real data can plausibly still be
  /// arriving converges on the right offset once it does, and costs nothing
  /// once it is already there - jumping to where it already is is a no-op.
  int _restoreAttemptsLeft = 6;

  void _restoreOrReveal() {
    if (!mounted || !_scrollController.hasClients) return;
    if (widget.selectedChannelId != _lastSelectedId) {
      _revealSelected();
      return;
    }
    if (_lastOffset <= 0) return;
    final position = _scrollController.position;
    if (position.hasContentDimensions) {
      _scrollController.jumpTo(
        _lastOffset.clamp(0.0, position.maxScrollExtent),
      );
    }
    if (--_restoreAttemptsLeft > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _restoreOrReveal());
    }
  }

  /// Same re-apply-across-a-few-frames shape as [_restoreOrReveal], and the
  /// same reason: the selected row's rect and the scroll view's real extent
  /// both depend on the channel list finishing its first stream emission.
  int _revealAttemptsLeft = 6;

  void _revealSelected() {
    if (!mounted || !_scrollController.hasClients) return;
    final rect = _markerLayerKey.currentState?.selectedRect;
    final position = _scrollController.position;
    if (rect != null && position.hasContentDimensions) {
      final viewport = position.viewportDimension;
      final offset = position.pixels;
      if (rect.top < offset) {
        _scrollController.jumpTo(rect.top);
      } else if (rect.bottom > offset + viewport) {
        _scrollController.jumpTo(
          (rect.bottom - viewport).clamp(0.0, position.maxScrollExtent),
        );
      }
    }
    if (--_revealAttemptsLeft > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
    }
  }

  @override
  void didUpdateWidget(CompactChannelRailDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedChannelId == oldWidget.selectedChannelId) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Scaffold.of(context).closeDrawer();
    });
  }

  /// How far the drawer has been dragged on past its open edge.
  double _carried = 0;

  /// How far past open a drag has to carry before it commits to the
  /// full-screen list.
  ///
  /// Deliberate travel on top of an already open drawer, so a drag that is only
  /// settling the drawer never reads as "go to the full-screen list".
  static const double _commitDistance = 80;

  void _onPointerMove(PointerMoveEvent event) {
    // Vertical wins ties, so scrolling the rail never accumulates its jitter.
    if (event.delta.dx.abs() <= event.delta.dy.abs()) return;
    // Leftward is Flutter's own drag-to-close; only the far side is ours.
    if (event.delta.dx < 0) {
      _carried = 0;
      return;
    }
    _carried += event.delta.dx;
    if (_carried < _commitDistance) return;
    _carried = 0;
    Scaffold.of(context).closeDrawer();
    context.go(Routes.channels);
  }

  /// A [Listener], never a [GestureDetector].
  ///
  /// A detector here would enter the gesture arena and win it, being deeper in
  /// the tree than the whole-screen drag Flutter's own `DrawerController` uses
  /// to pull the drawer closed - so claiming the horizontal axis to read the
  /// rightward half would take the leftward half away with it, and dragging
  /// the rail shut would stop working. `channel_rail_drawer_test.dart`'s own
  /// "dragging the rail closed dismisses it" caught exactly that. A listener
  /// observes the same pointers without claiming anything.
  @override
  Widget build(BuildContext context) => Drawer(
    child: Listener(
      onPointerDown: (_) => _carried = 0,
      onPointerMove: _onPointerMove,
      child: ChannelRail(
        scrollController: _scrollController,
        markerLayerKey: _markerLayerKey,
      ),
    ),
  );
}
