// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fade-and-rise a freshly arrived message rides in on, and the rule for
/// which arrivals get it: one at a time, at the bottom, never a burst.
library;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// Decides, once per transcript build, whether the newest row animates in.
///
/// Rows arriving closer together than the entrance itself lands would stack
/// several half-faded rows on top of each other, so a burst lands still.
/// See `docs/design/design-language.md` (Motion).
class EntranceGate {
  /// Newest ids already shown, so a recycle or unrelated rebuild never replays an entrance; capped at [_seenCap].
  final Set<String> _seen = {};
  static const _seenCap = 64;
  bool _hydrated = false;
  DateTime? _lastArrival;

  /// An arrival sooner than this after the previous one is part of a burst.
  static const Duration burstGap = AppMotion.base;

  /// Whether the newest of [ids] (oldest first) slides in; [atLatest] is
  /// whether the reader is at the bottom, where the row lands in view.
  bool admit(List<String> ids, {required bool atLatest}) {
    final arrived = _hydrated && !_seen.contains(ids.last);
    // The first build remembers the whole tail, which a deleted newest falls back to.
    _seen.addAll(_hydrated ? [ids.last] : ids);
    while (_seen.length > _seenCap) {
      _seen.remove(_seen.first);
    }
    _hydrated = true;
    if (!arrived) return false;
    final now = clock.now();
    final previous = _lastArrival;
    _lastArrival = now;
    final burst = previous != null && now.difference(previous) < burstGap;
    return atLatest && !burst;
  }
}

/// A one-shot fade-and-rise for a freshly arrived message. Keyed by its message
/// id by its caller, so the row keeps its state as later arrivals push it along;
/// [animateOnMount] is read once, when the row first mounts. Reads
/// reduce-motion once, on first layout, and lands instantly if set.
class MessageEntrance extends StatefulWidget {
  const MessageEntrance({
    super.key,
    required this.child,
    required this.animateOnMount,
    this.newest = false,
  });

  final Widget child;
  final bool animateOnMount;

  /// Whether this is the transcript's newest row; a newer one landing finishes this one's entrance at once.
  final bool newest;

  @override
  State<MessageEntrance> createState() => _MessageEntranceState();
}

class _MessageEntranceState extends State<MessageEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.base,
  );
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (widget.animateOnMount && !AppMotion.isReduced(context)) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(MessageEntrance oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Two rows mid-rise would overlap by the rise, so the older one lands now.
    if (oldWidget.newest && !widget.newest) _controller.value = 1;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _controller,
    child: widget.child,
    builder: (context, child) {
      final t = AppMotion.entrance.transform(_controller.value);
      return Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (1 - t) * 8),
          child: child,
        ),
      );
    },
  );
}
