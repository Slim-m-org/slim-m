// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The layer that paints the live toast queue above every screen.
///
/// Mounted once by `appChromeBuilder`, outside the routed tree, so a
/// confirmation fired from anywhere floats over whatever is on screen - a
/// dialog, a sheet, the title bar - rather than inside the surface that fired
/// it. Bottom-right where there is a pointer to dismiss with and room to spare
/// (a wide window); top-centre on a phone, where the thumb is far from the top
/// and a bottom toast would sit under the composer.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/dock_reservation.dart';
import '../providers/toasts.dart';

class ToastOverlay extends ConsumerWidget {
  const ToastOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final toasts = ref.watch(toastsProvider);
    if (toasts.isEmpty) return const SizedBox.shrink();

    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    final alignment = compact ? Alignment.topCenter : Alignment.bottomRight;
    // Newest nearest its edge: last in a bottom column, first in a top one.
    final ordered = compact ? toasts.reversed.toList() : toasts;
    // A bottom toast rises over a call dock or a resting mini-player rather than covering their controls.
    final lift = compact
        ? 0.0
        : math.max(
            ref.watch(bottomDockReservationProvider),
            ref.watch(miniPlayerReachProvider),
          );

    return SafeArea(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.s16).copyWith(
            // On a phone the toast clears the app bar, so it never covers the screen's title.
            top: compact ? kToolbarHeight : AppSpacing.s16,
            bottom: AppSpacing.s16 + lift,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: compact
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.end,
            children: [
              for (final toast in ordered)
                Padding(
                  key: ValueKey(toast.id),
                  padding: const EdgeInsets.only(top: AppSpacing.s8),
                  child: _ToastEntry(
                    fromTop: compact,
                    child: AppToast(
                      message: toast.message,
                      severity: toast.severity,
                      onDismiss: () =>
                          ref.read(toastsProvider.notifier).dismiss(toast.id),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Fades and slides one toast in from its edge on mount. Reduce-motion
/// collapses the slide to nothing and the fade to an instant show, the same
/// choke point every other animation in this app asks.
class _ToastEntry extends StatefulWidget {
  const _ToastEntry({required this.child, required this.fromTop});

  final Widget child;
  final bool fromTop;

  @override
  State<_ToastEntry> createState() => _ToastEntryState();
}

class _ToastEntryState extends State<_ToastEntry>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, not initState: the reduce-motion answer needs an inherited MediaQuery.
    if (_started) return;
    _started = true;
    _controller.duration = AppMotion.reduced(context, AppMotion.base);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final begin = Offset(0, widget.fromTop ? -0.15 : 0.15);
    return FadeTransition(
      opacity: _curve,
      child: SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(_curve),
        child: widget.child,
      ),
    );
  }
}
