// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every `confirmDangerousAction` call site's own copy, open over the shell.
///
/// The text is each call site's real wording, as `ui_overlay_snapshot_confirm_test.dart` copies it; the state is the variant slug.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/screens/admin/retention_section.dart'
    show retentionConfirmMessage;
import 'package:slimm_app/src/widgets/confirm_dialog.dart';

import '../ui_snapshot_support.dart';
import 'members_review_support.dart';

typedef _Copy = ({String title, String message, String confirm, String cancel});

_Copy _copy(
  String title,
  String message,
  String confirm, [
  String cancel = 'Cancel',
]) => (title: title, message: message, confirm: confirm, cancel: cancel);

final _deleteMessage = _copy(
  deleteMessageConfirmTitle,
  deleteMessageConfirmMessage,
  'Delete',
);

final _variants = <String, _Copy>{
  'delete-account': _copy(
    'Delete this account?',
    'Your devices, read state, and blocks are erased, and the username '
        'becomes available again.\n\nThis cannot be undone.',
    'Delete permanently',
    'Keep my account',
  ),
  'delete-message': _deleteMessage,
  'delete-reported-message': _deleteMessage,
  'delete-emoji': _copy(
    'Remove :wave:?',
    'Messages that already use it keep their text, but it stops '
        'rendering as an image. This cannot be undone.',
    'Remove',
  ),
  'delete-category': _copy(
    'Delete "Voice"?',
    'Its channels are never deleted with it - they fall back to '
        'uncategorised. This cannot be undone.',
    'Delete',
  ),
  'delete-role': _copy(
    'Delete "moderator"?',
    'Members holding this role lose whatever it grants '
        'immediately. This cannot be undone.',
    'Delete',
  ),
  'clear-canvas': _copy(
    'Clear this canvas?',
    'This removes everything on this canvas, including objects outside '
        'your current view, for everyone in this channel. You can undo this '
        'with Undo until you close the canvas or take many more actions.',
    'Clear canvas',
    'Keep canvas',
  ),
  'set-overwrite': _copy(
    'Replace this overwrite?',
    'This replaces the whole overwrite for @moderator in '
        '"#general": any permission left at "Inherit" above goes '
        'back to inheriting from their roles, even if it was allowed or '
        'denied before.',
    'Set overwrite',
  ),
  'clear-overwrite': _copy(
    'Clear this overwrite?',
    'Every permission for @moderator in "#general" '
        'goes back to inheriting from their roles. This cannot be undone.',
    'Clear',
  ),
  'eject-from-call': _copy(
    'Eject Ada Lovelace from this call?',
    'They will be disconnected from the call right now. Nothing stops '
        'them rejoining - time them out or remove them from the Space for '
        'something that sticks.',
    'Eject',
  ),
  'remove-from-space': _copy(
    'Remove Ada Lovelace from this Space?',
    'They will be signed out and cannot sign in again, and any '
        'invites they handed out stop working. Everything they wrote stays, '
        'still shown as theirs. You can let them back in later.',
    'Remove',
  ),
  'revoke-invite': _copy(
    'Revoke this invite?',
    'Anyone holding "AB12CD34EF" will no longer be '
        'able to redeem it. This cannot be undone.',
    'Revoke',
  ),
  'resolve-report': _copy(
    'Resolve this report?',
    'This marks it handled and removes it from the queue. It cannot '
        'be reopened from here.',
    'Resolve',
  ),
  'dismiss-report': _copy(
    'Dismiss this report?',
    'This closes it with no action taken and removes it from the '
        'queue. It cannot be reopened from here.',
    'Dismiss',
  ),
  'delete-channel': _copy(
    'Delete "general"?',
    'This deletes the channel and its message history for everyone '
        'in the Space. This cannot be undone.',
    'Delete permanently',
    'Keep channel',
  ),
  'sign-out-devices': _copy(
    'Sign out all other devices?',
    'Every device but this one is logged out right away and has to '
        'sign in again to use this account.',
    'Sign out all',
  ),
  'uninstall-module': _copy(
    'Uninstall Watch Party?',
    'Removes it from this space along with every permission it '
        'registered and every role grant of them. This cannot be undone.',
    'Uninstall',
  ),
  'retention-delete': _copy(
    'Delete messages older than 90 days?',
    retentionConfirmMessage(90, 1240),
    'Delete old messages',
  ),
  'clear-module-data': _copy(
    'Clear what Watch Party stored?',
    'It forgets everything it saved for this space. It stays installed '
        'with the same access.',
    'Clear data',
  ),
};

void main() {
  setUpAll(loadRealFonts);

  for (final variant in _variants.entries) {
    final copy = variant.value;
    reviewCase(
      'sheet-confirm-destructive',
      state: variant.key,
      drive: (rig) => rig.open(
        (context) => confirmDangerousAction(
          context,
          title: copy.title,
          message: copy.message,
          confirmLabel: copy.confirm,
          cancelLabel: copy.cancel,
        ),
      ),
    );
  }
}
