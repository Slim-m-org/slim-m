// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rows of buttons a bot attaches to its message. See
/// docs/decisions/0039-bot-message-buttons.md.
///
/// Layout follows the width it is given, never the platform: a row wraps
/// rather than scrolling, so five buttons fit a phone as two lines.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../external_link.dart';
import '../providers/button_presses.dart';

/// A failure stays a readable line under the row, not a full-width banner.
const double _errorMaxWidth = 480;

const double _hostMaxWidth = 220;

AppButtonVariant _variantFor(api.ComponentButtonStyle style) => switch (style) {
  // Soft, not filled: several may share a message and only one action per screen is filled.
  api.ComponentButtonStyle.primary => AppButtonVariant.soft,
  api.ComponentButtonStyle.secondary => AppButtonVariant.secondary,
  api.ComponentButtonStyle.danger => AppButtonVariant.danger,
  api.ComponentButtonStyle.link => AppButtonVariant.ghost,
};

/// [unavailable] disables every button, for a message whose bot is gone.
class MessageButtons extends ConsumerWidget {
  const MessageButtons({
    super.key,
    required this.channelId,
    required this.messageId,
    required this.rows,
    this.unavailable = false,
  });

  final String channelId;
  final String messageId;
  final List<api.ComponentRow> rows;
  final bool unavailable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rows.isEmpty) return const SizedBox.shrink();
    final presses = ref.watch(messageButtonPressesProvider(messageId));
    final controller = ref.read(buttonPressesProvider.notifier);
    void press(String customId) => unawaited(
      controller.press(
        channelId: channelId,
        messageId: messageId,
        customId: customId,
      ),
    );
    final failed = presses.values
        .where((p) => p.status == ButtonPressStatus.failed)
        .firstOrNull;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kMessageColumnMax),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s4),
              child: Wrap(
                spacing: AppSpacing.s4,
                runSpacing: AppSpacing.s4,
                children: [
                  for (final button in row.buttons)
                    _ButtonView(
                      button: button,
                      pending: presses[button.customId]?.pending ?? false,
                      disabled: unavailable || button.disabled,
                      onPressed: button.customId == null
                          ? null
                          : () => press(button.customId!),
                    ),
                ],
              ),
            ),
          if (failed != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _errorMaxWidth),
                child: AppErrorState(
                  message: failed.failure ?? 'That button did not work.',
                  onRetry: () {
                    controller.dismiss(messageId, failed.customId);
                    press(failed.customId);
                  },
                  onDismiss: () =>
                      controller.dismiss(messageId, failed.customId),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ButtonView extends StatelessWidget {
  const _ButtonView({
    required this.button,
    required this.pending,
    required this.disabled,
    required this.onPressed,
  });

  final api.MessageButton button;
  final bool pending;
  final bool disabled;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final isLink = button.style == api.ComponentButtonStyle.link;
    final url = button.url;
    AppButton build({required bool busy}) => AppButton(
      label: button.label,
      variant: _variantFor(button.style),
      size: AppButtonSize.sm,
      icon: isLink ? AppIcons.externalLink : null,
      disabled: disabled,
      busy: busy,
      onPressed: isLink
          ? (url == null ? null : () => unawaited(openExternalHttpUrl(url)))
          : onPressed,
    );
    if (isLink) return _WithHost(host: _hostOf(url), child: build(busy: false));
    if (!pending) return build(busy: false);
    // The invisible copy holds the label's width so the spinner swaps in without a reflow.
    return Stack(
      children: [
        Visibility(
          visible: false,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: build(busy: false),
        ),
        Positioned.fill(child: build(busy: true)),
      ],
    );
  }
}

/// The destination a link button opens, read off the url rather than the label.
String? _hostOf(String? url) {
  final host = url == null ? null : Uri.tryParse(url)?.host;
  return host == null || host.isEmpty ? null : host;
}

/// Puts the destination host under a link button, so a label cannot pose as another site.
class _WithHost extends StatelessWidget {
  const _WithHost({required this.host, required this.child});

  final String? host;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final host = this.host;
    if (host == null) return child;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        child,
        Padding(
          padding: const EdgeInsets.only(top: AppSpacing.s4),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _hostMaxWidth),
            child: Text(
              host,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}
