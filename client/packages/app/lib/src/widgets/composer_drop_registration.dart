// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A composer's slot in `composerAttachmentDropProvider`, kept out of its
/// State. Every write waits a frame because a bind or release can run inside
/// the very build that mounts or removes the composer, and a provider write
/// there is a build-time mutation.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/composer_attachment_drop.dart';

class ComposerDropRegistration {
  StateController<ComposerAttachmentDropTarget?>? _registry;

  /// What this composer last registered, so a late clear removes only its
  /// own entry and never a newer composer's for the same channel.
  ComposerAttachmentDropTarget? _target;

  /// Releases the previous channel's entry (none on the first call) and
  /// registers [target] under [channelId].
  void bind({
    required WidgetRef ref,
    required String channelId,
    required ComposerAttachmentDropTarget Function() target,
    required bool Function() isMounted,
  }) {
    final oldRegistry = _registry;
    final oldTarget = _target;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _clear(oldRegistry, oldTarget);
      if (!isMounted()) return;
      final registry = ref.read(
        composerAttachmentDropProvider(channelId).notifier,
      );
      final bound = target();
      registry.state = bound;
      _registry = registry;
      _target = bound;
    });
  }

  /// Captures the slot now: by the frame callback `ref` is already detached.
  void release() {
    final registry = _registry;
    final target = _target;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _clear(registry, target),
    );
  }

  static void _clear(
    StateController<ComposerAttachmentDropTarget?>? registry,
    ComposerAttachmentDropTarget? target,
  ) {
    if (registry != null && registry.mounted && registry.state == target) {
      registry.state = null;
    }
  }
}
