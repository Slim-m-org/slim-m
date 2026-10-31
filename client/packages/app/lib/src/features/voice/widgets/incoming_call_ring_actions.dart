// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What answering or dismissing a ring does, shared by both width surfaces.
library;

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/dm_call_ring_controller.dart';

void acceptRing(WidgetRef ref, IncomingDmCallRing ring) =>
    unawaited(ref.read(dmCallRingControllerProvider.notifier).accept(ring));

void declineRing(WidgetRef ref, IncomingDmCallRing ring) =>
    unawaited(ref.read(dmCallRingControllerProvider.notifier).decline(ring));

/// Escape declines rather than merely dismissing to a lesser state: the ring
/// keeps going on the caller's own side either way (`dm_call_ring_controller.dart`'s
/// own doc), so silently hiding this without telling the caller would leave
/// them waiting on an answer that already happened.
///
/// Requests focus explicitly on mount rather than relying on `autofocus`:
/// the routed tree's own page already holds focus in its `ModalRoute`'s own
/// scope by the time a ring can ever arrive, and passive `autofocus` only
/// claims a node when its enclosing scope holds none at all - it defers
/// rather than contesting a focus a sibling scope already has. An explicit
/// [FocusNode.requestFocus] call has no such deference, which is exactly
/// what "steal focus" means here - with no tab stop needed to reach it first.
class RingShortcuts extends ConsumerStatefulWidget {
  const RingShortcuts({super.key, required this.ring, required this.child});

  final IncomingDmCallRing ring;
  final Widget child;

  @override
  ConsumerState<RingShortcuts> createState() => _RingShortcutsState();
}

class _RingShortcutsState extends ConsumerState<RingShortcuts> {
  final _focusNode = FocusNode(debugLabel: 'IncomingCallOverlay');

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: {
      const SingleActivator(LogicalKeyboardKey.escape): () =>
          declineRing(ref, widget.ring),
    },
    child: Focus(focusNode: _focusNode, child: widget.child),
  );
}
