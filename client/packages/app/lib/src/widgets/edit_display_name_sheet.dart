// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sheet personal settings' own header opens: renaming the caller's
/// display name. `PATCH /me` (`SlimmApi.updateMe`).
///
/// Length is checked here so the button disables before a doomed request
/// goes out; the character rule (no control or text-direction characters) is
/// not re-checked client-side at all, deliberately. `validate_label`
/// (`crates/slimm-server/src/http/auth.rs`) exists because a name that can
/// spoof how it renders is a safety problem, and a client-side sanitiser
/// that silently stripped those characters would launder exactly the input
/// that check exists to refuse. A rejection is shown honestly instead, via
/// [describeApiFailure].
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../api_failure.dart';
import '../providers/providers.dart';

/// Matches the server's own ceiling (`validate_label` in
/// `crates/slimm-server/src/http/auth.rs`), so the counter here never
/// disagrees with the length check the request will actually be judged
/// against.
const int _displayNameMaxChars = 64;

Future<void> showEditDisplayNameSheet(BuildContext context, String current) {
  return showAppSheet<void>(
    context,
    builder: (context) => _EditDisplayNameSheet(current: current),
  );
}

class _EditDisplayNameSheet extends ConsumerStatefulWidget {
  const _EditDisplayNameSheet({required this.current});

  final String current;

  @override
  ConsumerState<_EditDisplayNameSheet> createState() =>
      _EditDisplayNameSheetState();
}

class _EditDisplayNameSheetState extends ConsumerState<_EditDisplayNameSheet> {
  late final _name = TextEditingController(text: widget.current);
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _dirty => _name.text.trim() != widget.current;

  int get _length => _name.text.trim().runes.length;

  bool get _nameValid => _length > 0 && _length <= _displayNameMaxChars;

  bool get _canSave => !_saving && _dirty && _nameValid;

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiProvider).updateMe(displayName: _name.text.trim());
      // updateMe returns a UserProfile, not the Me shape meProvider holds, so refetch rather than merge.
      ref.invalidate(meProvider);
      if (mounted) Navigator.of(context).pop();
    } on api.ApiException catch (e) {
      if (mounted) {
        setState(() => _error = describeApiFailure('save your name', e));
      }
    } finally {
      // Any escape, not just ApiException, must not wedge "Saving..." on.
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final length = _length;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        MediaQuery.viewInsetsOf(context).bottom + AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Edit display name',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _name,
              placeholder: 'Display name',
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSave) unawaited(_save());
              },
              semanticLabel: 'Display name',
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$length/$_displayNameMaxChars',
                style: AppText.micro.copyWith(
                  color: length > _displayNameMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: _error!),
            ],
            const SizedBox(height: AppSpacing.s12),
            AppButton(
              label: _saving ? 'Saving...' : 'Save name',
              variant: AppButtonVariant.primary,
              full: true,
              disabled: !_canSave,
              onPressed: _save,
            ),
          ],
        ),
      ),
    );
  }
}
