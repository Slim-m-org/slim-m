// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The small form a bot opens for a press: a few fields and a submit. A short
/// task with a submit is `showAppSheet` (docs/design/desktop-vs-mobile.md
/// rule 4), a bottom sheet under 600 and a dialog above. See
/// docs/decisions/0082-bot-token-reissue-select-menus-and-forms.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../ids.dart';
import '../../../providers/live_events.dart';
import '../../../providers/providers.dart';
import '../../../widgets/labeled_field.dart';
import '../providers/bot_forms.dart';

/// How long a submission waits for the bot before it says so.
const Duration botFormTimeout = Duration(seconds: 5);

Future<void> showBotFormSheet(BuildContext context, BotFormRequest request) =>
    showAppSheet<void>(
      context,
      scrolls: true,
      builder: (context) => BotFormSheet(request: request),
    );

class BotFormSheet extends ConsumerStatefulWidget {
  const BotFormSheet({
    super.key,
    required this.request,
    this.timeout = botFormTimeout,
  });

  final BotFormRequest request;
  final Duration timeout;

  @override
  ConsumerState<BotFormSheet> createState() => _BotFormSheetState();
}

class _BotFormSheetState extends ConsumerState<BotFormSheet> {
  late final Map<String, TextEditingController> _controllers = {
    for (final field in widget.request.form.fields)
      field.customId: TextEditingController(text: field.value),
  };
  StreamSubscription<api.ServerEvent>? _answers;
  Timer? _timer;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    unawaited(_answers?.cancel());
    _timer?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  bool get _complete => widget.request.form.fields.every(
    (f) => !f.required || _controllers[f.customId]!.text.trim().isNotEmpty,
  );

  Future<void> _submit() async {
    final id = newMessageId();
    setState(() {
      _busy = true;
      _error = null;
    });
    unawaited(_answers?.cancel());
    _answers = ref.read(liveEventsProvider).listen((event) {
      if (event case api.InteractionAnswered(
        :final interactionId,
      ) when interactionId == id) {
        _timer?.cancel();
        if (mounted) Navigator.of(context).pop();
      }
    });
    _timer?.cancel();
    _timer = Timer(
      widget.timeout,
      () => _fail(
        'The bot did not answer. It may be offline, so try again in a moment.',
      ),
    );
    try {
      await ref
          .read(apiProvider)
          .submitInteractionForm(
            channelId: widget.request.channelId,
            interactionId: widget.request.interactionId,
            id: id,
            fields: {
              for (final entry in _controllers.entries)
                entry.key: entry.value.text,
            },
          );
    } on api.ApiException catch (e, stack) {
      api.reportFailure(api.LogTag.ui, 'submit the form', e, stack);
      _fail(
        e is api.NotFoundException
            ? 'That form is no longer available. Press the button again.'
            : describeApiFailure('send the form', e),
      );
    }
  }

  void _fail(String message) {
    _timer?.cancel();
    unawaited(_answers?.cancel());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final form = widget.request.form;
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
          Row(
            children: [
              Expanded(
                child: Text(
                  form.title,
                  style: AppText.heading.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.semi,
                  ),
                ),
              ),
              AppIconButton(
                icon: AppIcons.dismiss,
                semanticLabel: 'Close',
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: AppSpacing.s12,
                children: [
                  const SizedBox(height: AppSpacing.s4),
                  for (final field in form.fields) _field(field),
                ],
              ),
            ),
          ),
          if (_error case final error?) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(
              message: error,
              onRetry: _complete ? _submit : null,
              onDismiss: () => setState(() => _error = null),
            ),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: form.submitLabel ?? 'Submit',
            variant: AppButtonVariant.primary,
            full: true,
            busy: _busy,
            disabled: _busy || !_complete,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }

  Widget _field(api.BotFormField field) => LabeledField(
    label: field.required ? field.label : '${field.label} (optional)',
    child: AppInput(
      controller: _controllers[field.customId],
      placeholder: field.placeholder,
      maxLength: field.maxLength,
      semanticLabel: field.label,
      minLines: field.multiline ? 3 : null,
      maxLines: field.multiline ? 6 : null,
      enabled: !_busy,
      onChanged: (_) => setState(() {}),
      onSubmitted: field.multiline ? null : (_) => _complete ? _submit() : null,
    ),
  );
}
