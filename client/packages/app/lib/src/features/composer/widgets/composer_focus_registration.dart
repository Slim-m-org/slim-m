// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A composer's slot in `composerFocusNodeProvider`, kept out of its State.
///
/// Captured once rather than read from `ref` on release: by then Riverpod has
/// already detached the element's `ref`, and reading it throws. Every write
/// waits a frame because bind and release can run inside the very build that
/// swaps the composer out (for `BlockedDmNotice` among others), and a provider
/// write from there is a build-time mutation, which Riverpod rejects outside
/// tests too.
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
