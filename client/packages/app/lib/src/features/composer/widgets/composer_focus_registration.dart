// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A composer's slot in `composerFocusNodeProvider`, kept out of its State.
/// Captured once because Riverpod detaches `ref` before release; every write waits a frame because bind and release can run inside the build that swaps the composer out.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/composer_focus.dart';

class ComposerFocusRegistration {
  StateController<FocusNode?>? _registry;

  void bind(
    WidgetRef ref,
    FocusNode focus, {
    required bool Function() isMounted,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted()) return;
      final registry = ref.read(composerFocusNodeProvider.notifier);
      registry.state = focus;
      _registry = registry;
    });
  }

  /// Clears the slot only if it still holds [focus], never a newer composer's.
  void release(FocusNode focus) {
    final registry = _registry;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (registry != null && registry.mounted && registry.state == focus) {
        registry.state = null;
      }
    });
  }
}
