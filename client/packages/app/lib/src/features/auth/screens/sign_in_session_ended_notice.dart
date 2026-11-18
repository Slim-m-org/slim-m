// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Why somebody is looking at the sign-in screen they did not navigate to.
///
/// A session the server ended - most often because another device signed this
/// one out - lands here with nothing said, which reads as the app having
/// forgotten them. Shown only for an involuntary end, never after Sign Out.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SessionStore;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart';
import '../../../widgets/server_notice.dart';

class SessionEndedNotice extends ConsumerWidget {
  const SessionEndedNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    if (!session.endedByServer) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
      child: ServerNotice(
        icon: AppIcons.signOut,
        message: session.lastEndReason == SessionStore.signedOutInAnotherTab
            ? 'You were signed out in another tab. Sign in again to carry on.'
            : 'You were signed out. This device was signed out from another '
                  'device, or its session expired. Sign in again to carry on.',
      ),
    );
  }
}
