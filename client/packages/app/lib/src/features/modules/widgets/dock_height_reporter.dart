// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Measures [child]'s real rendered height after every frame and publishes
/// it to `bottomDockReservationProvider`, so `app_snackbar.dart` knows how
/// much of the bottom edge a floating dock actually occupies right now.
///
/// Measured rather than guessed at a fixed constant: the dock this wraps
/// stacks one row or two depending on width and on whether a call is
/// present (`CanvasCallDock`'s own doc comment), so a hardcoded height would
/// either under-reserve on the tallest shape or waste space on the shortest
/// one. Publishes 0 on dispose, since a dock that has unmounted reserves
/// nothing.
///
/// A reader that takes [DockHeightReporter.onHeight] or `onWidth` relays out a
/// screen per report, so it hears a size only once the card has stopped
/// tweening; the shared reservation still follows every frame.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/dock_reservation.dart';

class DockHeightReporter extends ConsumerStatefulWidget {
  const DockHeightReporter({
    super.key,
    required this.child,
    this.onHeight,
    this.onWidth,
    this.reservation,
    this.foldedHeight,
    this.extraHeight = 0,
  });

  /// Published instead of the measured height while the dock is folded away,
  /// so what it reserves is what is still on screen. Null while it is showing.
  final double? foldedHeight;

  /// What sits above [child] and belongs to the dock's footprint, such as a fold handle.
  final double extraHeight;

  final Widget child;

  /// Told the measured height instead of the shared reservation, for a dock
  /// whose only reader is its own screen and not the shell's snackbars.
  final ValueChanged<double>? onHeight;

  /// Told the measured width, for a screen that keeps its dock's footprint to itself.
  final ValueChanged<double>? onWidth;

  /// Where the height is published; the shared dock reservation when null.
  final StateProvider<double>? reservation;

  @override
  ConsumerState<DockHeightReporter> createState() => _DockHeightReporterState();
}

class _DockHeightReporterState extends ConsumerState<DockHeightReporter> {
  final _key = GlobalKey();

  /// Captured once: a disposed [ConsumerState] cannot read `ref` again, and
  /// the reservation this dock owns must still be zeroed out on the way down.
  late final StateController<double> _reservation = ref.read(
    (widget.reservation ?? bottomDockReservationProvider).notifier,
  );
  late final StateController<double> _width = ref.read(
    bottomDockWidthProvider.notifier,
  );
  double _lastReported = 0;
  double _lastWidth = 0;
  Size? _lastSeen;
  bool _published = false;
  bool _reportQueued = false;

  /// Who published each reservation last, so a dock leaving does not zero a height another dock now holds.
  static final _publisher = Expando<_DockHeightReporterState>();

  bool get _local => widget.onHeight != null || widget.onWidth != null;

  /// One report per frame, so two consecutive reports are always two frames apart.
  void _queueReport() {
    if (_reportQueued) return;
    _reportQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _reportQueued = false;
      _report();
    });
  }

  /// A local reader relays out a whole screen per report, so it waits for the card to stop tweening.
  bool _stillMoving(Size? size) {
    final moving = _local && _published && size != _lastSeen;
    _lastSeen = size;
    if (moving) {
      _queueReport();
      // The tween's last frame leaves nothing else to look again.
      WidgetsBinding.instance.scheduleFrame();
    }
    return moving;
  }

  void _report() {
    if (!mounted) return;
    final size = _key.currentContext?.size;
    if (_stillMoving(size)) return;
    _published = true;
    final measured = size?.height ?? 0;
    final height = widget.foldedHeight ?? measured + widget.extraHeight;
    _reportWidth(widget.foldedHeight == null ? size?.width ?? 0 : 0);
    if (height == _lastReported) return;
    _lastReported = height;
    _publisher[_reservation] = this;
    final local = widget.onHeight;
    if (local != null) {
      local(height);
      return;
    }
    _reservation.state = height;
  }

  /// Only the shared dock publishes a width; a dock that keeps its height to itself keeps this too.
  void _reportWidth(double width) {
    widget.onWidth?.call(width);
    if (widget.onHeight != null || widget.reservation != null) return;
    if (width == _lastWidth) return;
    _lastWidth = width;
    _width.state = width;
  }

  /// Deferred to a microtask: Riverpod refuses a provider write made
  /// synchronously inside `dispose`, since the tree is still mid-teardown -
  /// caught only by a real unmount, never by a unit test on this class alone.
  /// The `mounted` check guards the other half of that same race: by the
  /// time the microtask runs, the whole `ProviderContainer` (this app's own
  /// at shutdown, or a test's own during teardown) may already be gone.
  @override
  void dispose() {
    final local = widget.onHeight != null;
    Future.microtask(() {
      if (local || !_reservation.mounted) return;
      if (_publisher[_reservation] == this) {
        _publisher[_reservation] = null;
        _reservation.state = 0;
        if (_lastWidth > 0 && _width.mounted) _width.state = 0;
      }
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _queueReport();
    // The card animates its own size, which no rebuild of this widget would see.
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _queueReport();
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}
