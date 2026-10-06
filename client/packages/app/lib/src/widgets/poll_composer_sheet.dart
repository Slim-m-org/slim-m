// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet the composer's poll button opens: a question and 2-4 options,
/// sent through `POST /channels/{id}/messages/polls`
/// ([api.SlimmApiMessages.sendPollMessage]).
///
/// Options are a real add/remove list now, not four fixed fields with the
/// last two marked "(optional)": [_minOptions]/[_maxOptions] mirror the
/// server's own `store::polls::{MIN_OPTIONS, MAX_OPTIONS}`, and a row past
/// the minimum carries its own remove button. A live, inert preview of
/// [PollView] renders below the fields as they are typed, so what "Send
/// poll" produces is not a guess.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LengthLimitingTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../ids.dart';
import '../providers/message_extras.dart';
import '../providers/providers.dart';
import 'poll_view.dart';

/// Mirrors `store::polls::MIN_OPTIONS`: below this a poll is not a choice.
const _minOptions = 2;

/// Mirrors `store::polls::MAX_OPTIONS`.
const _maxOptions = 4;

/// Mirrors `store::polls::MAX_QUESTION_CHARS`.
const _maxQuestionChars = 300;

/// Mirrors `store::polls::MAX_OPTION_CHARS`.
const _maxOptionChars = 100;

/// Not `const`: [LengthLimitingTextInputFormatter] has no const constructor.
final _questionFormatters = [
  LengthLimitingTextInputFormatter(_maxQuestionChars),
];
final _optionFormatters = [LengthLimitingTextInputFormatter(_maxOptionChars)];

Future<void> showPollComposerSheet(BuildContext context, String channelId) {
  return showAppSheet<void>(
    context,
    builder: (context) => _PollComposerSheet(channelId: channelId),
  );
}

class _PollComposerSheet extends ConsumerStatefulWidget {
  const _PollComposerSheet({required this.channelId});

  final String channelId;

  @override
  ConsumerState<_PollComposerSheet> createState() => _PollComposerSheetState();
}

class _PollComposerSheetState extends ConsumerState<_PollComposerSheet> {
  final _question = TextEditingController();
  final _options = List.generate(_minOptions, (_) => TextEditingController());

  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _question.dispose();
    for (final controller in _options) {
      controller.dispose();
    }
    super.dispose();
  }

  List<String> get _filledOptions =>
      _options.map((c) => c.text.trim()).where((t) => t.isNotEmpty).toList();

  bool get _canSubmit =>
      !_submitting &&
      _question.text.trim().isNotEmpty &&
      _filledOptions.length >= _minOptions;

  /// Names what is missing rather than sitting disabled with no reason -
  /// the same "say why" treatment the design language asks of any control
  /// that cannot currently be used.
  String get _buttonLabel {
    if (_submitting) return 'Sending...';
    if (_question.text.trim().isEmpty) return 'Add a question';
    if (_filledOptions.length < _minOptions) return 'Add at least 2 options';
    return 'Send poll';
  }

  void _addOption() {
    if (_options.length >= _maxOptions) return;
    setState(() => _options.add(TextEditingController()));
  }

  void _removeOption(int index) {
    if (_options.length <= _minOptions) return;
    setState(() => _options.removeAt(index).dispose());
  }

  Future<void> _submit() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final sent = await ref
          .read(apiProvider)
          .sendPollMessage(
            channelId: widget.channelId,
            id: newMessageId(),
            question: _question.text.trim(),
            options: _filledOptions,
          );
      final store = await ref.read(storeProvider.future);
      await store.applyMessage(sent);
      ref.read(messageExtrasProvider.notifier).applyMessage(sent);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('send the poll', e));
      }
    } finally {
      // Any escape, not just ApiException, must not wedge "Sending..." on.
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// The same [PollView] the transcript renders, fed placeholder text for
  /// whatever has not been typed yet, so a still-empty field shows its own
  /// row rather than nothing - the composer's option count is exactly the
  /// preview's option count.
  api.Poll get _previewPoll => api.Poll(
    question: _question.text.trim().isEmpty
        ? 'Your question'
        : _question.text.trim(),
    options: [
      for (var i = 0; i < _options.length; i++)
        api.PollOption(
          position: i,
          label: _options[i].text.trim().isEmpty
              ? 'Option ${i + 1}'
              : _options[i].text.trim(),
          votes: 0,
        ),
    ],
    totalVotes: 0,
    votedOption: null,
    closeAt: null,
    closed: false,
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final canAddOption = _options.length < _maxOptions;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'New poll',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              '$_minOptions to $_maxOptions options, one vote each.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _question,
              placeholder: 'Ask a question',
              autofocus: true,
              inputFormatters: _questionFormatters,
              onChanged: (_) => setState(() {}),
              semanticLabel: 'Poll question',
            ),
            const SizedBox(height: AppSpacing.s8),
            AnimatedSize(
              duration: AppMotion.reduced(context, AppMotion.fast),
              alignment: Alignment.topCenter,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _options.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                      child: Row(
                        children: [
                          Expanded(
                            child: AppInput(
                              controller: _options[i],
                              placeholder: 'Option ${i + 1}',
                              inputFormatters: _optionFormatters,
                              onChanged: (_) => setState(() {}),
                              semanticLabel: 'Option ${i + 1}',
                            ),
                          ),
                          // Only for a row past the minimum: the first two options are required, so nothing removes them.
                          if (i >= _minOptions) ...[
                            const SizedBox(width: AppSpacing.s8),
                            AppIconButton(
                              icon: AppIcons.dismiss,
                              semanticLabel: 'Remove option ${i + 1}',
                              onPressed: () => _removeOption(i),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (canAddOption)
              AppButton(
                label: 'Add option',
                icon: AppIcons.add,
                variant: AppButtonVariant.ghost,
                full: true,
                onPressed: _addOption,
              )
            else
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.s8),
                child: Text(
                  'Maximum of $_maxOptions options.',
                  style: AppText.caption.copyWith(color: tokens.textSecondary),
                ),
              ),
            const SizedBox(height: AppSpacing.s12),
            Text(
              'Preview',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s4),
            // Inert: nothing here can be voted on, and a closed badge would not be true of a poll that does not exist yet.
            IgnorePointer(
              child: Opacity(
                opacity: 0.7,
                child: ExcludeSemantics(
                  child: PollView(poll: _previewPoll, onVote: (_) {}),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            if (_error != null) ...[
              AppErrorState(message: _error!),
              const SizedBox(height: AppSpacing.s8),
            ],
            AppButton(
              label: _buttonLabel,
              variant: AppButtonVariant.primary,
              full: true,
              disabled: !_canSubmit,
              onPressed: _submit,
            ),
          ],
        ),
      ),
    );
  }
}
