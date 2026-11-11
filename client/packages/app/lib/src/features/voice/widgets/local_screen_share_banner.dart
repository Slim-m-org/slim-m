// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pending half of a screen share: a system picker the caller has to go
/// answer. A live share has no banner (decision 0047, point 8): the share
/// control and the stage caption carry it.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/status_banner.dart';
import '../providers/voice_controller.dart';

/// Says a share is requested but not yet live, which a bare spinner on the
/// share button cannot. `info`, never accent: nothing is being shared yet.
class LocalScreenSharePendingBanner extends ConsumerWidget {
  const LocalScreenSharePendingBanner({super.key});

  /// The cancel button, for a caller's test to find inside its own banner.
  static const cancelKey = Key('pending-share-cancel');

  @override
  Widget build(BuildContext context, WidgetRef ref) => StatusBanner(
    sticky: true,
    icon: AppIcons.screenShare,
    message: 'Start the broadcast to share.',
    margin: const EdgeInsets.only(top: AppSpacing.s12),
    action: AppButton(
      key: cancelKey,
      size: AppButtonSize.sm,
      label: 'Cancel',
      onPressed: () => unawaited(
        ref.read(voiceControllerProvider.notifier).share.setScreenShare(false),
      ),
    ),
  );
}
