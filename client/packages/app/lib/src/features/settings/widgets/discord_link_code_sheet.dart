// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet that finishes a Discord link with the code the browser page
/// shows, for when its "Open slim-m" button does not reach the app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/labeled_field.dart';
import '../providers/discord_link_finish.dart';

const _maxPasteChars = 128;

/// Opens the code prompt.
Future<void> showDiscordLinkCodeSheet(BuildContext context) =>
    showAppSheet<void>(context, builder: (_) => const _DiscordLinkCodeSheet());

class _DiscordLinkCodeSheet extends ConsumerStatefulWidget {
  const _DiscordLinkCodeSheet();

  @override
  ConsumerState<_DiscordLinkCodeSheet> createState() =>
      _DiscordLinkCodeSheetState();
}

class _DiscordLinkCodeSheetState extends ConsumerState<_DiscordLinkCodeSheet> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final finisher = ref.read(discordLinkFinisherProvider);
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await finisher.complete(_code.text);
    if (!mounted) return;
    if (failure == null) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      key: const ValueKey('discord-link-code-sheet'),
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
                  'Finish linking Discord',
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
          const SizedBox(height: AppSpacing.s8),
          LabeledField(
            label: 'Link code',
            helper: 'Shown on the page Discord sent you back to.',
            child: AppInput(
              key: const ValueKey('discord-link-code-field'),
              controller: _code,
              maxLength: _maxPasteChars,
              autofocus: true,
              autocorrect: false,
              mono: true,
              semanticLabel: 'Discord link code',
              onSubmitted: (_) => _busy ? null : _submit(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: AppSpacing.s8),
            AppErrorState(message: _error!),
          ],
          const SizedBox(height: AppSpacing.s12),
          AppButton(
            label: _busy ? 'Linking...' : 'Link',
            variant: AppButtonVariant.primary,
            full: true,
            disabled: _busy,
            onPressed: _submit,
          ),
        ],
      ),
    );
  }
}
