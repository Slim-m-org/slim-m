// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A free-text status line ("in a meeting", "afk"), edited in place from
/// personal settings' own Presence section and shown in the member pane
/// under a name (`member_pane.dart`'s own row) - the same "rides `users`
/// like `display_name`" shape `crates/slimm-server/src/http/users.rs`'s
/// `UpdateMeRequest` uses, and the same `Event::ProfileChanged` invalidation
/// the display-name edit already relies on: no dedicated live event exists
/// for this, or is needed, since a rename and a status edit both go through
/// the one event that already tells every other client to re-ask.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Unprefixed extension methods need the declaring library imported - see api.dart's own `show` list comment.
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/member_presence.dart' show memberProfileOverridesProvider;
import '../providers/providers.dart';
import 'run_guarded.dart';

/// Matches the server's own ceiling (`STATUS_TEXT_MAX_CHARS` in
/// `crates/slimm-server/src/http/user_status.rs`), so the counter here never
/// disagrees with the length check the request will actually be judged
/// against.
const int statusTextMaxChars = 80;

/// Characters as the server counts them (`chars().count()`), so an emoji is
/// one, not the two UTF-16 units `String.length` would give it.
int statusTextLength(String text) => text.trim().runes.length;

/// Reads the caller's current status off [meProvider] and hands it to
/// [_StatusTextField] under a key derived from it, so the field's own
/// controller re-seeds itself whenever the server's value genuinely
/// changes (a fresh load, a save round-tripping through [meProvider]'s own
/// invalidation) without a live edit in progress ever being overwritten by
/// a rebuild that resolves to the same value it already holds.
class StatusTextRow extends ConsumerWidget {
  const StatusTextRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(meProvider);
    if (!me.hasValue) return const SizedBox.shrink();
    final current = me.value!.statusText ?? '';
    return _StatusTextField(key: ValueKey(current), current: current);
  }
}

class _StatusTextField extends ConsumerStatefulWidget {
  const _StatusTextField({super.key, required this.current});

  /// What the server currently holds, trimmed. The field's own controller is
  /// seeded from this once, at construction - never re-read after, which is
  /// what lets a fresh [ValueKey] (see [StatusTextRow]) be the only thing
  /// that can reset an in-progress edit.
  final String current;

  @override
  ConsumerState<_StatusTextField> createState() => _StatusTextFieldState();
}

class _StatusTextFieldState extends ConsumerState<_StatusTextField>
    with GuardedActionState<_StatusTextField> {
  late final _controller = TextEditingController(text: widget.current);
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _dirty => _controller.text.trim() != widget.current;
  bool get _valid => statusTextLength(_controller.text) <= statusTextMaxChars;
  bool get _canSave => !_saving && _dirty && _valid;

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await guard(
      whatFailed: 'update your status',
      action: () async {
        final profile = await ref
            .read(apiProvider)
            .updateMe(statusText: _controller.text.trim());
        ref.invalidate(meProvider);
        ref.read(memberProfileOverridesProvider.notifier).applyKnown(profile);
      },
    );
    // A failure leaves the field as typed; a success gets its reconciliation from [meProvider] resolving, not from here.
    if (mounted) setState(() => _saving = false);
    if (!ok) return;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final length = statusTextLength(_controller.text);

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.s8,
        vertical: AppSpacing.s8,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Status text',
            style: AppText.ui.copyWith(color: tokens.textPrimary),
          ),
          const SizedBox(height: AppSpacing.s4),
          AppInput(
            controller: _controller,
            placeholder: 'What are you up to?',
            semanticLabel: 'Status text',
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) {
              if (_canSave) unawaited(_save());
            },
          ),
          const SizedBox(height: AppSpacing.s4),
          Row(
            children: [
              Text(
                '$length/$statusTextMaxChars',
                style: AppText.micro.copyWith(
                  color: length > statusTextMaxChars
                      ? tokens.dangerText
                      : tokens.textSecondary,
                ),
              ),
              const Spacer(),
              if (_dirty)
                AppButton(
                  label: _saving ? 'Saving...' : 'Save',
                  variant: AppButtonVariant.ghost,
                  disabled: !_canSave,
                  onPressed: _save,
                ),
            ],
          ),
          if (actionError != null) ...[
            const SizedBox(height: AppSpacing.s4),
            AppErrorState(message: actionError!, onDismiss: clearActionError),
          ],
        ],
      ),
    );
  }
}
