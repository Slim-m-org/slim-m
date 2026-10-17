// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Prompts for a report's reason before filing one: the one piece of free
/// text `POST /reports` requires alongside what is being reported.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Asks why [subjectLabel] is being reported. Returns the trimmed reason,
/// or null if the caller cancelled. The server rejects a blank reason
/// anyway, so the submit button stays disabled until there is one.
///
/// Routed through [showAppSheet] rather than a bare `AlertDialog`, so it
/// matches every other modal's chrome and gets the same phone/desktop split.
Future<String?> promptReportReason(
  BuildContext context, {
  required String subjectLabel,
}) => showAppSheet<String>(
  context,
  builder: (context) => _ReportReasonSheet(subjectLabel: subjectLabel),
);

/// Owns its own controller rather than one the caller disposes: the sheet's
/// future resolves as soon as the route is popped, well before its exit
/// transition finishes animating this content out, so disposing on the
/// caller's side raced that transition and used the controller after
/// disposing it. A widget's own `dispose()` only runs once the element is
/// actually removed, which is what this needs.
class _ReportReasonSheet extends StatefulWidget {
  const _ReportReasonSheet({required this.subjectLabel});

  final String subjectLabel;

  @override
  State<_ReportReasonSheet> createState() => _ReportReasonSheetState();
}

class _ReportReasonSheetState extends State<_ReportReasonSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSubmit => _controller.text.trim().isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Report ${widget.subjectLabel}',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s12),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            maxLength: 2000,
            style: AppText.body.copyWith(color: tokens.textPrimary),
            cursorColor: tokens.accent,
            decoration: const InputDecoration(
              hintText: 'What is wrong with it?',
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.s8),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: 'Cancel',
                  variant: AppButtonVariant.ghost,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: AppSpacing.s8),
              Expanded(
                child: AppButton(
                  label: 'Report',
                  variant: AppButtonVariant.primary,
                  disabled: !_canSubmit,
                  onPressed: () =>
                      Navigator.of(context).pop(_controller.text.trim()),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
