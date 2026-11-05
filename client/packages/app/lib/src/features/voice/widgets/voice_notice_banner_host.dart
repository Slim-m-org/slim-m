// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Puts [VoiceNoticeBanner] above the signed-in shell while a voice notice is showing.
///
/// Mounts no banner, and so no `SafeArea`, when there is nothing to show; see [BannerHostLayout].
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../../widgets/banner_host_layout.dart';
import '../providers/voice_notice_controller.dart';

class VoiceNoticeBannerHost extends ConsumerWidget {
  const VoiceNoticeBannerHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notice = ref.watch(voiceNoticeProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return BannerHostLayout(
      banner: notice == null
          ? null
          : Material(
              color: tokens.surfaceBase,
              child: SafeArea(
                bottom: false,
                child: VoiceNoticeBanner(notice: notice),
              ),
            ),
      child: child,
    );
  }
}

/// "Ada started a call in #lounge" with a way to look and a way to wave it off.
class VoiceNoticeBanner extends ConsumerWidget {
  const VoiceNoticeBanner({super.key, required this.notice});

  final VoiceNoticeItem notice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final controller = ref.read(voiceNoticeProvider.notifier);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final message = Text(
      notice.text,
      key: const Key('voice-notice-text'),
      style: TextStyle(color: tokens.textPrimary),
    );
    final actions = Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: [
        AppButton(
          key: const Key('voice-notice-open'),
          label: 'Open',
          size: AppButtonSize.sm,
          onPressed: () {
            controller.dismiss();
            // Arrives without joining; the call is one tap away on the same screen.
            context.go(Routes.channel(notice.channelId, openChat: true));
          },
        ),
        AppButton(
          key: const Key('voice-notice-dismiss'),
          label: 'Dismiss',
          variant: AppButtonVariant.secondary,
          size: AppButtonSize.sm,
          onPressed: controller.dismiss,
        ),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final inline = constraints.maxWidth >= _inlineWidth;
        return AppCallout(
          tone: AppCalloutTone.info,
          icon: AppIcons.voice,
          centred: inline,
          child: inline
              ? Row(
                  children: [
                    Expanded(child: message),
                    const SizedBox(width: AppSpacing.s12),
                    actions,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    message,
                    const SizedBox(height: AppSpacing.s8),
                    actions,
                  ],
                ),
        );
      },
    );
  }
}

/// Below this the message and its two answers stop fitting on one line.
const double _inlineWidth = 640;
