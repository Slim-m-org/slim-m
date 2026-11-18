// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fade-and-rise a freshly arrived message rides in on, and the rule for
/// which arrivals get it: one after a quiet stretch, at the bottom, never a
/// stream.
library;

import 'package:clock/clock.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import 'transcript_items.dart';

/// Decides, once per transcript build, whether the newest row animates in.
///
/// A row rises in only after a quiet stretch: a steady stream stacks or
/// chains entrances into constant motion, so it lands still until it stops.
/// See `docs/design/design-language.md` (Motion).
class EntranceGate {
  /// Highest arrival position admitted so far, per [_OrderKind], never lowered.
  final Map<_OrderKind, int> _highest = {};
  String? _newestId;
  bool _hydrated = false;
  DateTime? _lastArrival;

  /// Forgets every arrival, so the next build only records what is on screen.
  void reset() {
    _highest.clear();
    _newestId = null;
    _hydrated = false;
    _lastArrival = null;
  }

  /// How long arrivals must pause before the next one rises in again.
  static const Duration quietGap = Duration(milliseconds: 800);

  /// Whether the newest of [items] (oldest first) slides in; [atLatest] is
  /// whether the reader is at the bottom, where the row lands in view.
  bool admit(List<TranscriptItem> items, {required bool atLatest}) {
    final newest = items.last;
    final (kind, at) = _orderOf(newest);
    // A send landing keeps its id and gains a seq, which is not a second arrival.
    final arrived = _hydrated && newest.id != _newestId && _isNewer(kind, at);
    // Every row counts, so one a delete or discard exposes is never newer than what was shown.
    for (final item in items) {
      final (kind, at) = _orderOf(item);
      if (_isNewer(kind, at)) _highest[kind] = at;
    }
    _newestId = newest.id;
    _hydrated = true;
    if (!arrived) return false;
    final now = clock.now();
    final previous = _lastArrival;
    _lastArrival = now;
    final quiet = previous == null || now.difference(previous) >= quietGap;
    return atLatest && quiet;
  }

  bool _isNewer(_OrderKind kind, int at) {
    final highest = _highest[kind];
    return highest == null || at > highest;
  }

  /// Delivered rows order by seq; an unsent send (seq 0) and a private answer
  /// carry only a clock time, so each is compared within its own kind.
  static (_OrderKind, int) _orderOf(TranscriptItem item) => switch (item) {
    StoredItem(:final message) when message.seq > 0 => (
      _OrderKind.delivered,
      message.seq,
    ),
    StoredItem(:final message) => (_OrderKind.local, message.createdAt),
    PrivateItem(:final message) => (_OrderKind.private, message.createdAt),
  };
}

enum _OrderKind { delivered, local, private }

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
