// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `confirmDangerousAction` variants `ui_overlay_snapshot_test.dart`'s
/// own `confirm-dialog` entry does not show: that one instance is the
/// delete-account copy, and every other call site has its own title and
/// message. Split into a sibling file for the same reason
/// `ui_overlay_snapshot_menus_test.dart` is one: keeping the growing set of
/// entries under this repo's own line budget.
///
/// Each entry below is the real copy from its own call site, not a
/// paraphrase - see screen-inventory-overlays.md's "confirm-dialog variants"
/// table for exactly which file each one lives in. Same split as every
/// sibling: the overflow assertion runs everywhere, the PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1.
///
/// The clear-canvas entry's copy names no count (the pane only holds the
/// objects near the view, not the whole canvas) and never says "cannot be
/// undone" - see canvas_overflow_menu.dart's own doc: a clear genuinely arms Undo,
/// server-backed, and this dialog must not say otherwise to the same
/// audience whose own dock proves it wrong.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/widgets/confirm_dialog.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

/// One dialog per call site, keyed by this file's own state id.
final _confirms = <String, FutureOr<void> Function(BuildContext)>{
  'confirm-delete-message': (context) => confirmDangerousAction(
    context,
    title: deleteMessageConfirmTitle,
    message: deleteMessageConfirmMessage,
    confirmLabel: 'Delete',
  ),
  'confirm-delete-reported-message': (context) => confirmDangerousAction(
    context,
    title: deleteMessageConfirmTitle,
    message: deleteMessageConfirmMessage,
    confirmLabel: 'Delete',
  ),
  'confirm-delete-emoji': (context) => confirmDangerousAction(
    context,
    title: 'Remove :wave:?',
    message:
        'Messages that already use it keep their text, but it stops '
        'rendering as an image. This cannot be undone.',
    confirmLabel: 'Remove',
  ),
  'confirm-delete-category': (context) => confirmDangerousAction(
    context,
    title: 'Delete "Voice"?',
    message:
        'Its channels are never deleted with it - they fall back to '
        'uncategorised. This cannot be undone.',
    confirmLabel: 'Delete',
  ),
  'confirm-delete-role': (context) => confirmDangerousAction(
    context,
    title: 'Delete "moderator"?',
    message:
        'Members holding this role lose whatever it grants '
        'immediately. This cannot be undone.',
    confirmLabel: 'Delete',
  ),
  // See this file's own doc comment for why this copy is what it is.
  'confirm-clear-canvas': (context) => confirmDangerousAction(
    context,
    title: 'Clear this canvas?',
    message:
        'This removes everything on this canvas, including objects outside '
        'your current view, for everyone in this channel. You can undo this '
        'with Undo until you close the canvas or take many more actions.',
    confirmLabel: 'Clear canvas',
    cancelLabel: 'Keep canvas',
  ),
  'confirm-set-overwrite': (context) => confirmDangerousAction(
    context,
    title: 'Replace this overwrite?',
    message:
        'This replaces the whole overwrite for @moderator in '
        '"#general": any permission left at "Inherit" above goes '
        'back to inheriting from their roles, even if it was allowed or '
        'denied before.',
    confirmLabel: 'Set overwrite',
  ),
  'confirm-clear-overwrite': (context) => confirmDangerousAction(
    context,
    title: 'Clear this overwrite?',
    message:
        'Every permission for @moderator in "#general" '
        'goes back to inheriting from their roles. This cannot be undone.',
    confirmLabel: 'Clear',
  ),
  'confirm-eject-from-call': (context) => confirmDangerousAction(
    context,
    title: 'Eject Ada Lovelace from this call?',
    message:
        'They will be disconnected from the call right now. Nothing stops '
        'them rejoining - time them out or remove them from the Space for '
        'something that sticks.',
    confirmLabel: 'Eject',
  ),
  'confirm-remove-from-space': (context) => confirmDangerousAction(
    context,
    title: 'Remove Ada Lovelace from this Space?',
    message:
        'They will be signed out and cannot sign in again, and any '
        'invites they handed out stop working. Everything they wrote stays, '
        'still shown as theirs. You can let them back in later.',
    confirmLabel: 'Remove',
  ),
  'confirm-revoke-invite': (context) => confirmDangerousAction(
    context,
    title: 'Revoke this invite?',
    message:
        'Anyone holding "AB12CD34EF" will no longer be '
        'able to redeem it. This cannot be undone.',
    confirmLabel: 'Revoke',
  ),
  'confirm-resolve-report': (context) => confirmDangerousAction(
    context,
    title: 'Resolve this report?',
    message:
        'This marks it handled and removes it from the queue. It cannot '
        'be reopened from here.',
    confirmLabel: 'Resolve',
  ),
  'confirm-dismiss-report': (context) => confirmDangerousAction(
    context,
    title: 'Dismiss this report?',
    message:
        'This closes it with no action taken and removes it from the '
        'queue. It cannot be reopened from here.',
    confirmLabel: 'Dismiss',
  ),
};

const _viewports = <String, Size>{
  'desktop': Size(1400, 880),
  'phone': Size(390, 844),
};

GoRouter _router(FutureOr<void> Function(BuildContext) open) => GoRouter(
  initialLocation: '/start',
  routes: [
    GoRoute(
      path: '/start',
      builder: (context, state) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => open(context),
            child: const Text('open confirm'),
          ),
        ),
      ),
    ),
  ],
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in _viewports.entries) {
    for (final confirm in _confirms.entries) {
      testWidgets('${confirm.key} at ${viewport.key} fits its viewport', (
        tester,
      ) async {
        tester.view.physicalSize = viewport.value;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          ProviderScope(
            child: RepaintBoundary(
              key: snapshotBoundary,
              child: MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: buildTheme(Brightness.dark, AppTokens.dark),
                routerConfig: _router(confirm.value),
              ),
            ),
          ),
        );
        await tester.pump();

        await tester.tap(find.text('open confirm'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));

        final snapshotName = '${confirm.key}-${viewport.key}';
        await expectSettled(tester, snapshotName);
        await writeSnapshot(tester, snapshotName);

        expect(tester.takeException(), isNull);
      });
    }
  }
}
