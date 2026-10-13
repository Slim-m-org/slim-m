// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The admin's control for renaming the Space, at the top of the landing page
/// section because the name sits beside the icon everywhere it shows.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show SlimmApiSpace;
import 'package:slimm_design_system/design_system.dart';

import '../providers/providers.dart';
import 'channel_rail_frame.dart' show serverInfoProvider;
import 'join_policy_row.dart';
import 'run_guarded.dart';

/// Matches the server's cap on a Space name.
const int kSpaceNameMaxChars = 64;

class SpaceNameField extends ConsumerStatefulWidget {
  const SpaceNameField({super.key, required this.saved});

  /// The name the server holds now.
  final String saved;

  @override
  ConsumerState<SpaceNameField> createState() => _SpaceNameFieldState();
}

class _SpaceNameFieldState extends ConsumerState<SpaceNameField>
    with GuardedActionState<SpaceNameField> {
  late final _name = TextEditingController(text: widget.saved);
  late String _saved = widget.saved;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final text = _name.text.trim();
    setState(() => _busy = true);
    clearActionError();
    final ok = await guard(
      whatFailed: 'rename the Space',
      action: () async {
        final updated = await ref
            .read(apiProvider)
            .setSpaceSettings(name: text);
        _saved = updated.name;
        _name.text = updated.name;
      },
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(spaceSettingsProvider);
    ref.invalidate(serverInfoProvider);
  }

  @override
  Widget build(BuildContext context) {
    final text = _name.text.trim();
    final changed = text.isNotEmpty && text != _saved;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppInput(
                controller: _name,
                placeholder: 'Space name',
                semanticLabel: 'Space name',
                enabled: !_busy,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(kSpaceNameMaxChars),
                ],
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => changed ? _save() : null,
              ),
            ),
            const SizedBox(width: AppSpacing.s8),
            AppButton(
              label: 'Rename',
              variant: AppButtonVariant.primary,
              size: AppButtonSize.sm,
              disabled: _busy || !changed,
              onPressed: _save,
            ),
          ],
        ),
        if (actionError != null) ...[
          const SizedBox(height: AppSpacing.s8),
          AppErrorState(message: actionError!, onDismiss: clearActionError),
        ],
      ],
    );
  }
}
