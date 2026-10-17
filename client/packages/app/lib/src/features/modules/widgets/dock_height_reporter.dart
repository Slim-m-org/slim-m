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
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/dock_reservation.dart';

class DockHeightReporter extends ConsumerStatefulWidget {
  const DockHeightReporter({super.key, required this.child, this.onHeight});

  final Widget child;

  /// Told the measured height instead of the shared reservation, for a dock
  /// whose only reader is its own screen and not the shell's snackbars.
  final ValueChanged<double>? onHeight;

  @override
  ConsumerState<DockHeightReporter> createState() => _DockHeightReporterState();
}

class _DockHeightReporterState extends ConsumerState<DockHeightReporter> {
  final _key = GlobalKey();

  /// Captured once: a disposed [ConsumerState] cannot read `ref` again, and
  /// the reservation this dock owns must still be zeroed out on the way down.
  late final StateController<double> _reservation = ref.read(
    bottomDockReservationProvider.notifier,
  );
  double _lastReported = 0;

  void _report() {
    final height = _key.currentContext?.size?.height ?? 0;
    if (height == _lastReported) return;
    _lastReported = height;
    final local = widget.onHeight;
    if (local != null) {
      local(height);
      return;
    }
    _reservation.state = height;
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
      if (!local && _reservation.mounted) _reservation.state = 0;
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
    // The card animates its own size, which no rebuild of this widget would see.
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _report());
        return false;
      },
      child: SizeChangedLayoutNotifier(
        child: KeyedSubtree(key: _key, child: widget.child),
      ),
    );
  }
}
