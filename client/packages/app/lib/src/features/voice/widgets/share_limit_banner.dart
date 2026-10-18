// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tells the sharer, once per share, that the encoder is holding it back.
library;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

/// Shown above the stage while [limit] is set; dismissing it keeps it away for the rest of that share.
class ShareLimitBanner extends StatelessWidget {
  const ShareLimitBanner({
    super.key,
    required this.limit,
    required this.onDismiss,
  });

  final ValueListenable<ShareLimit?> limit;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ShareLimit?>(
    valueListenable: limit,
    builder: (context, value, _) {
      if (value == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: AppSpacing.s12),
        child: AppCallout(
          tone: AppCalloutTone.warn,
          icon: AppIcons.screenShare,
          child: Row(
            children: [
              Expanded(child: Text(shareLimitMessage(value))),
              const SizedBox(width: AppSpacing.s8),
              AppButton(
                label: 'Dismiss',
                size: AppButtonSize.sm,
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// What the sharer can do about [limit].
String shareLimitMessage(ShareLimit limit) => switch (limit) {
  ShareLimit.cpu =>
    'Your computer cannot keep up with this share. Try a lower resolution '
        'or frame rate in the share options.',
  ShareLimit.bandwidth =>
    'Your connection cannot carry this share at full quality. Try a lower '
        'resolution or frame rate in the share options.',
};
