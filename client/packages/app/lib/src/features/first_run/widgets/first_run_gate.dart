// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts first-run setup above the shell while it is owed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show AppFadeIn;

import '../providers/first_run_controller.dart';
import 'first_run_flow.dart';

class FirstRunGate extends ConsumerWidget {
  const FirstRunGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(firstRunControllerProvider);
    return Stack(
      children: [
        // The shell stays mounted so sync carries on; nothing under the setup takes focus or taps.
        Positioned.fill(
          child: ExcludeFocus(
            excluding: state.active,
            child: IgnorePointer(ignoring: state.active, child: child),
          ),
        ),
        if (state.active)
          const Positioned.fill(
            child: AppFadeIn(offset: 0, child: FirstRunFlow()),
          ),
      ],
    );
  }
}
