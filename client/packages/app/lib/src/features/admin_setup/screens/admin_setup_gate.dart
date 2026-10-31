// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts the admin setup above the shell once the member welcome is out of the way.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show AppFadeIn;

import '../../first_run/providers/first_run_controller.dart';
import '../providers/admin_setup_controller.dart';
import 'admin_setup_flow.dart';

class AdminSetupGate extends ConsumerWidget {
  const AdminSetupGate({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(
      adminSetupControllerProvider.select((s) => s.active),
    );
    final welcoming = ref.watch(
      firstRunControllerProvider.select((s) => s.active),
    );
    final showing = active && !welcoming;
    return Stack(
      children: [
        // The shell stays mounted so sync carries on; nothing under the setup takes focus or taps.
        Positioned.fill(
          child: ExcludeFocus(
            excluding: showing,
            child: IgnorePointer(ignoring: showing, child: child),
          ),
        ),
        if (showing)
          const Positioned.fill(
            child: AppFadeIn(offset: 0, child: AdminSetupFlow()),
          ),
      ],
    );
  }
}
