// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The biometric app lock's own layer around `appChromeBuilder`'s stack:
/// renders `AppLockScreen` over [child] while `appLockControllerProvider`
/// reports locked, and nothing extra otherwise.
///
/// An overlay rather than a swap of the routed app for the lock screen (the
/// shape `ClientTooOldGate` uses for its own, unrecoverable state): the
/// routed `Navigator` underneath stays mounted the whole time slim-m is
/// locked, so a resume-triggered lock never loses scroll position, an
/// in-progress compose draft, or any other state a rebuilt tree would drop.
///
/// A cover only stops pointer hits, so while locked [child] is also removed
/// from keyboard focus (which drops whatever held it, a composer included) and
/// from the semantics tree. System back is swallowed by
/// `AppLockController.didPopRoute`, since this sits above the `Router`.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_lock_controller.dart';
import 'app_lock_screen.dart';

class AppLockGate extends ConsumerWidget {
  const AppLockGate({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locked = ref.watch(appLockControllerProvider);
    return Stack(
      children: [
        ExcludeFocus(
          excluding: locked,
          child: ExcludeSemantics(excluding: locked, child: child),
        ),
        if (locked) const Positioned.fill(child: AppLockScreen()),
      ],
    );
  }
}
