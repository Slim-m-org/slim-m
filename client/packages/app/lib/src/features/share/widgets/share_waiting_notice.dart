// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells a signed-out person why the sign-in screen is in front of what they
/// just shared: the share resumes once they are in.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/server_notice.dart';
import '../providers/incoming_share.dart';

class ShareWaitingNotice extends ConsumerWidget {
  const ShareWaitingNotice({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(pendingShareProvider) == null) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(bottom: AppSpacing.s8),
      child: ServerNotice(
        icon: AppIcons.share,
        message: 'Sign in to finish sharing.',
      ),
    );
  }
}
