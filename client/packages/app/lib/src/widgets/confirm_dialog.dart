// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one confirmation sheet: a title, what happens, and a way out beside
/// the choice. Every yes-or-no question in the app asks through it.
///
/// Routed through [showAppSheet] rather than a bare `AlertDialog`, so it gets
/// the same border-first card, radius and phone/desktop split every other
/// modal in the app already has - a raw `AlertDialog` draws Material's own
/// 28dp-radius, shadowed card, which reads as a different app mid-flow.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The shared confirmation copy for deleting a message, used identically by
/// `channel_message_actions.dart` (a message's own actions menu) and
/// `report_card_actions.dart` (a moderator deleting a reported message) - one
/// constant rather than two call sites hand-typing the same words, so an
/// edit to one cannot leave the other one word off without changing both.
const String deleteMessageConfirmTitle = 'Delete message?';
const String deleteMessageConfirmMessage =
    'This removes it for everyone in the channel. This cannot be undone.';

/// Asks before a destructive, hard-to-undo action. [message] must state what
/// happens, not just ask "are you sure?".
Future<bool> confirmDangerousAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
}) => confirmChoice(
  context,
  title: title,
  message: message,
  confirmLabel: confirmLabel,
  cancelLabel: cancelLabel,
  confirmVariant: AppButtonVariant.danger,
);

/// True when the person picks [confirmLabel]; false when they pick
/// [cancelLabel] or close the sheet.
///
/// [cancelLabel] names the way out where "Cancel" is vaguer than the choice
/// deserves. A destructive choice goes through [confirmDangerousAction].
Future<bool> confirmChoice(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  String cancelLabel = 'Cancel',
  AppButtonVariant confirmVariant = AppButtonVariant.primary,
  Key? confirmKey,
  Key? cancelKey,
}) async {
  final confirmed = await showAppSheet<bool>(
    context,
    builder: (context) => _ConfirmSheet(
      title: title,
      message: message,
      confirm: (label: confirmLabel, key: confirmKey),
      cancel: (label: cancelLabel, key: cancelKey),
      confirmVariant: confirmVariant,
    ),
  );
  return confirmed ?? false;
}

typedef _Choice = ({String label, Key? key});

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({
    required this.title,
    required this.message,
    required this.confirm,
    required this.cancel,
    required this.confirmVariant,
  });

  final String title;
  final String message;
  final _Choice confirm;
  final _Choice cancel;
  final AppButtonVariant confirmVariant;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          Text(
            message,
            style: AppText.body.copyWith(color: tokens.textSecondary),
          ),
          const SizedBox(height: AppSpacing.s16),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  key: cancel.key,
                  label: cancel.label,
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  key: confirm.key,
                  label: confirm.label,
                  variant: confirmVariant,
                  onPressed: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
