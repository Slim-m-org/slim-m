// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An administrator renaming somebody else's account inside this Space
/// (`PUT`/`DELETE /members/{userId}/nickname`, decision 0055).
///
/// A nickname is what every reader sees; the account's own name stays what the
/// account chose and is still shown to them in their own profile. So this sheet
/// says so, and offers to remove the nickname as readily as to set one. Length
/// is checked here so the button disables before a doomed request; the
/// character rule is left to the server, as in `edit_display_name_sheet.dart`.
///
/// `showAppSheet`, so a bottom sheet on a phone and a centred dialog on a
/// desktop (`docs/design/desktop-vs-mobile.md`, rule 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart' show membersProvider;
import '../providers/providers.dart';
import 'run_guarded.dart';

const int _nicknameMaxChars = 64;

Future<void> showRenameMemberSheet(
  BuildContext context, {
  required api.UserProfile profile,
}) => showAppSheet<void>(
  context,
  builder: (context) => _RenameMemberSheet(profile: profile),
);

/// The Moderate sub-view's row for [showRenameMemberSheet].
class RenameMemberMenuItem extends StatelessWidget {
  const RenameMemberMenuItem({
    super.key,
    required this.host,
    required this.profile,
    required this.onDone,
  });

  /// A context that outlives the popover; see `member_profile.dart`'s `host`.
  final BuildContext host;
  final api.UserProfile profile;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => AppMenuItem(
    label: 'Rename...',
    leading: AppIcons.edit,
    submenu: true,
    onTap: () {
      onDone();
      unawaited(showRenameMemberSheet(host, profile: profile));
    },
  );
}

class _RenameMemberSheet extends ConsumerStatefulWidget {
  const _RenameMemberSheet({required this.profile});

  final api.UserProfile profile;

  @override
  ConsumerState<_RenameMemberSheet> createState() => _RenameMemberSheetState();
}

class _RenameMemberSheetState extends ConsumerState<_RenameMemberSheet>
    with GuardedActionState<_RenameMemberSheet> {
  late final _name = TextEditingController(text: widget.profile.nickname ?? '');
  bool _busy = false;

  String get _accountName =>
      widget.profile.accountDisplayName ?? widget.profile.displayName;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _canSave {
    final trimmed = _name.text.trim();
    return !_busy &&
        trimmed.isNotEmpty &&
        trimmed.runes.length <= _nicknameMaxChars &&
        trimmed != widget.profile.nickname;
  }

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    setState(() => _busy = true);
    final ok = await guard(whatFailed: whatFailed, action: action);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) return;
    ref.invalidate(membersProvider);
    Navigator.of(context).pop();
  }

  Future<void> _save() => _run(
    'rename ${widget.profile.displayName}',
    () => ref
        .read(apiProvider)
        .setMemberNickname(
          userId: widget.profile.id,
          nickname: _name.text.trim(),
        ),
  );

  Future<void> _remove() => _run(
    'remove the nickname',
    () => ref.read(apiProvider).clearMemberNickname(widget.profile.id),
  );

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final length = _name.text.trim().runes.length;
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
              'Rename ${widget.profile.displayName}',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            const SizedBox(height: AppSpacing.s4),
            Text(
              'Everyone in this Space sees this name. Their own name, '
              '$_accountName, stays in their profile and is not changed.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            const SizedBox(height: AppSpacing.s12),
            AppInput(
              controller: _name,
              placeholder: _accountName,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (_canSave) unawaited(_save());
              },
              semanticLabel: 'Nickname',
            ),
            const SizedBox(height: AppSpacing.s4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '$length/$_nicknameMaxChars',
                style: AppText.micro.copyWith(
                  color: length > _nicknameMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
            ),
            if (actionError != null) ...[
              const SizedBox(height: AppSpacing.s8),
              AppErrorState(message: actionError!, onDismiss: clearActionError),
            ],
            const SizedBox(height: AppSpacing.s12),
            Row(
              children: [
                if (widget.profile.nickname != null) ...[
                  Expanded(
                    child: AppButton(
                      label: 'Remove nickname',
                      variant: AppButtonVariant.ghost,
                      disabled: _busy,
                      onPressed: _remove,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.s8),
                ],
                Expanded(
                  child: AppButton(
                    label: _busy ? 'Saving...' : 'Save name',
                    variant: AppButtonVariant.primary,
                    disabled: !_canSave,
                    onPressed: _save,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
