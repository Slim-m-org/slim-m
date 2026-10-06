// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop-anchored status menu's own free-text editor: an [AppInput]
/// that submits on Enter, replacing the dialog hop `status_editor_sheet.dart`
/// still needs on a compact width. Per `docs/design/desktop-vs-mobile.md`
/// rule 2, a control that stays on screen (status) gets a dropdown, not a
/// modal - the free-text editor was the one part of the status menu still
/// escalating to a dialog. Split out of `presence_menu.dart` to keep that
/// file under this repo's 300-line review budget; see its own library doc.
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
import 'status_text_row.dart' show statusTextLength, statusTextMaxChars;

/// Seeded once from [current] at construction - the caller hands a fresh
/// instance per menu presentation (the same instance-per-open contract
/// `presence_menu.dart`'s own `_PresenceMenuItems` documents), so nothing
/// here needs to react to a value changing out from under an edit in
/// progress the way `status_editor_sheet.dart`'s field does not either.
class PresenceStatusField extends ConsumerStatefulWidget {
  const PresenceStatusField({
    super.key,
    required this.current,
    required this.onDone,
  });

  /// What the server held when the menu opened, trimmed.
  final String current;

  /// Closes the presentation this is shown in - called only once the server
  /// has agreed to the new text, so a refusal leaves the field open with
  /// [actionError] rendered inline rather than closing over a change that
  /// never landed.
  final VoidCallback onDone;

  @override
  ConsumerState<PresenceStatusField> createState() =>
      _PresenceStatusFieldState();
}

class _PresenceStatusFieldState extends ConsumerState<PresenceStatusField>
    with GuardedActionState<PresenceStatusField> {
  late final _controller = TextEditingController(text: widget.current);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Applies [text] to the server, then patches the member pane's own copy
  /// of this profile with the response - not a blanket `ref.invalidate` of
  /// the whole roster - so the caller's own row updates the moment this
  /// resolves rather than waiting on the next unrelated roster refetch. See
  /// `memberProfileOverridesProvider`'s own doc comment for why the roster
  /// provider itself cannot just be patched in place.
  Future<void> _apply(String text) async {
    final ok = await guard(
      whatFailed: text.isEmpty ? 'clear your status' : 'update your status',
      action: () async {
        final profile = await ref.read(apiProvider).updateMe(statusText: text);
        ref.invalidate(meProvider);
        ref.read(memberProfileOverridesProvider.notifier).applyKnown(profile);
      },
    );
    if (ok && mounted) widget.onDone();
  }

  Future<void> _submit() {
    final text = _controller.text.trim();
    if (statusTextLength(text) > statusTextMaxChars) return Future.value();
    return _apply(text);
  }

  /// The owner's own ask: a small clear affordance inline in the field
  /// itself rather than a separate always-there-when-set "Clear status" menu
  /// row below it, the standard clearable-field pattern this app's other
  /// search inputs do not need only because none of them writes anywhere.
  Future<void> _clear() {
    setState(_controller.clear);
    return _apply('');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final length = statusTextLength(_controller.text);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppInput(
            controller: _controller,
            placeholder: 'What are you up to?',
            // Never widget.onDone here: a keystroke must not close the menu on someone still typing.
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => unawaited(_submit()),
            semanticLabel: 'Status text',
            trailing: length == 0
                ? null
                : AppIconButton(
                    icon: AppIcons.dismiss,
                    semanticLabel: 'Clear status',
                    size: AppIconButtonSize.sm,
                    onPressed: () => unawaited(_clear()),
                  ),
          ),
          const SizedBox(height: AppSpacing.s4),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '$length/$statusTextMaxChars',
              style: AppText.micro.copyWith(
                color: length > statusTextMaxChars
                    ? tokens.dangerText
                    : tokens.textSecondary,
              ),
            ),
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
