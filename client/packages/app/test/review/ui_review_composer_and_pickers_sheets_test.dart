// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three sheets the composer opens: the touch "More actions" list, the
/// poll composer, and the code insert picker. Dark and light; the PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1.
///
/// The actions sheet exists at touch density only: a desktop window shows
/// those actions as buttons on the bar, so it has no desktop capture.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_extras.dart';
import 'package:slimm_app/src/features/composer/widgets/poll_composer_sheet.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';
import 'package:slimm_design_system/design_system.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

void _noop() {}

void _actions(String state, {bool paste = false, bool apps = false}) =>
    reviewCases(
      'sheet-composer-actions',
      state: state,
      viewports: const ['phone'],
      body: (tester, viewport) => reviewShadowed(
        (themes) => reviewOverlay(
          tester,
          surface: 'sheet-composer-actions',
          state: state,
          viewport: viewport,
          themes: themes,
          open: (context, ref) => showComposerActionsSheet(
            context,
            onPhotoLibrary: _noop,
            onBrowseFiles: _noop,
            canPasteImage: Future.value(paste),
            onPasteImage: _noop,
            onPoll: _noop,
            onCode: _noop,
            onApps: apps ? _noop : null,
          ),
        ),
      ),
    );

Finder _field(String placeholder) => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == placeholder,
);

Future<void> _fill(WidgetTester tester, String placeholder, String text) async {
  await tester.enterText(_field(placeholder), text);
  await tester.pump();
}

Future<void> _addOptions(WidgetTester tester, List<String> labels) async {
  for (final (i, label) in labels.indexed) {
    if (i >= 2) {
      await tester.tap(find.text('Add option'));
      await settle(tester);
    }
    await _fill(tester, 'Option ${i + 1}', label);
  }
}

void _poll(
  String state, {
  List<Override> overrides = const [],
  Future<void> Function(WidgetTester tester)? fill,
}) => reviewCases(
  'sheet-poll-composer',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewOverlay(
      tester,
      surface: 'sheet-poll-composer',
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: overrides,
      open: (context, ref) => showPollComposerSheet(context, 'c-general'),
      afterOpen: (tester, _) async {
        await settle(tester);
        await fill?.call(tester);
      },
    ),
  ),
);

Future<void> _openCode(WidgetTester tester, String viewport) async {
  if (viewport == 'phone') {
    await tester.tap(find.byTooltip('More actions'));
    await settle(tester);
    await tester.tap(find.text('Insert code'));
  } else {
    await tester.tap(find.byTooltip('Insert code'));
  }
  await settle(tester);
}

void _code(String state, {String? filter}) => reviewCases(
  'sheet-code-insert-picker',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewRoute(
      tester,
      surface: 'sheet-code-insert-picker',
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: [
        codeBlockRunnerProvider.overrideWith(
          (ref) async => const [
            api.CodeBlockRunner(
              moduleId: 'runner',
              command: 'run',
              language: 'python',
            ),
          ],
        ),
      ],
      act: (tester, _) async {
        await _openCode(tester, viewport);
        if (filter == null) return;
        await _fill(tester, 'Filter languages', filter);
        await settle(tester);
      },
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  _actions('default');
  _actions('with-paste', paste: true);
  _actions('with-apps', paste: true, apps: true);

  _poll('empty');
  _poll(
    'four-options',
    fill: (tester) async {
      await _fill(tester, 'Ask a question', 'Which map for the next event?');
      await _addOptions(tester, ['Ruins', 'Harbour', 'Foundry', 'Skip it']);
    },
  );
  _poll(
    'ranked',
    fill: (tester) async {
      await _fill(tester, 'Ask a question', 'Where should we meet on Friday?');
      await _addOptions(tester, [
        'The usual cafe',
        'Board game shop',
        'Online',
      ]);
      await tester.tap(
        find.byWidgetPredicate(
          (w) => w is AppToggle && w.semanticLabel == 'Ranked choice',
        ),
      );
      await settle(tester);
    },
  );
  _poll(
    'error',
    overrides: [
      ReviewServer(
        extra: (request) =>
            request.url.path == '/channels/c-general/messages/polls'
            ? Future.value(jsonResponse({'error': 'forbidden'}, 403))
            : null,
      ).override,
    ],
    fill: (tester) async {
      await _fill(tester, 'Ask a question', 'Pizza or tacos for the offsite?');
      await _addOptions(tester, ['Pizza', 'Tacos']);
      await tester.tap(find.text('Send poll'));
      await settleRequest(tester);
    },
  );

  _code('default');
  _code('filtered', filter: 'py');
  _code('no-match', filter: 'zzzq');
}
