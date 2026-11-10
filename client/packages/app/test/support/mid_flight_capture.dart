// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Fails a captured surface whose settle budget was not actually enough:
/// see CLAUDE.md's "The report card overflow, and how far the mid-flight
/// capture problem actually spreads" for the bug this exists to catch.
///
/// `ui_snapshot_support.dart`'s own settle budget (two or three fixed
/// pumps) is a guess about how long a surface's async work takes, not a
/// proof that it is finished. The report card overflow shipped invisible
/// because a card's own `initState` fires a *second*, nested resolve that
/// needed one more turn of the event loop than that budget gave it, and
/// until it landed the row showed the short, harmless placeholder
/// `'Loading...'` rather than the real, overflowing name - so every prior
/// capture of that screen was quietly checking a not-yet-loaded state.
///
/// [expectSettled] does not trust the settle budget either: it reads every
/// visible string right where the budget says "done", pumps a further
/// [extraSettlePumps] frames of [extraSettleFrame] each (a timed pump
/// cannot hang the way `pumpAndSettle` does on a perpetual spinner - it
/// advances the clock once and paints one frame, it never loops waiting for
/// quiescence), and reads the same strings again. A real, finished product
/// state cannot change what it says just because time passed; a placeholder
/// still waiting on its own async hop, or content fading in from a ticker
/// that only started on the budget's final frame, can.
///
/// The frames are timed, not bare, because of the second shape this caught
/// shipping invisibly: `AppAsyncView` mounts its resolved content inside an
/// `AppFadeIn`, whose ticker starts when the DATA mounts, not when the
/// screen does. A fetch landing on the settle budget's final frame put the
/// whole admin pane on screen at opacity zero - present in the widget tree,
/// absent from the pixels - and bare pumps advance no time, so the fade
/// never moved and the capture read as stable. [renderedText] therefore
/// also skips text a person cannot see (any ancestor at ~zero opacity):
/// with timed frames, such content transitions invisible-to-visible during
/// the extra pumps and fails as the mid-flight capture it is.
///
/// A settled surface can still be wrong in a way the comparison above can
/// never catch: a stable BLANK. `before == after == []` reads as
/// "identical", so the mid-flight check alone would wave a content-free
/// screen through - a surface that renders nothing settles into agreeing
/// with itself just as cleanly as one that rendered correctly.
/// [expectSettled] additionally fails when the settled read has no visible
/// text at all, unless [allowNoText] says this surface is genuinely
/// text-free (a pure canvas/graphic, say).
///
/// This only catches a surface with truly nothing on screen. A route pushed
/// over `ui_snapshot_support.dart`'s base channel shell (every settings and
/// admin surface) keeps that base shell's own text mounted underneath, so a
/// pane that renders empty while its surrounding chrome still has a title
/// cannot reach an empty [renderedText] this way; only a standalone route
/// can demonstrate this check failing.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Frames pumped past the declared settle budget before deciding a surface
/// is actually done: headroom for a resolve chained a couple of hops deep
/// (the report card's own shape) and, timed, for an entrance fade whose
/// ticker started on the budget's last frame.
const extraSettlePumps = 3;

/// Together the [extraSettlePumps] advance 360ms, past `AppMotion.slow`'s
/// 280ms ceiling, so no chrome entrance can still be mid-flight after them.
const extraSettleFrame = Duration(milliseconds: 120);

/// Every string a person reading the screen would see, in tree order:
/// [Text.data], or [Text.textSpan]'s own plain-text rendering for a rich
/// span (mentions, inline code, and the markdown-rendered message body all
/// go through [Text.rich]).
///
/// "Would see" is literal: text under an ancestor faded to (near) zero -
/// an `AppFadeIn` at its own t=0, an [Opacity] or [FadeTransition] holding
/// zero - is skipped, because pixels are what a snapshot captures and a
/// tree-only read is exactly how a whole invisible admin pane once passed
/// as settled.
List<String> renderedText(WidgetTester tester) {
  final strings = <String>[];
  for (final element in tester.elementList(find.byType(Text))) {
    if (_hiddenByOpacity(element)) continue;
    final text = element.widget as Text;
    final data = text.data;
    if (data != null) {
      strings.add(data);
    } else if (text.textSpan != null) {
      strings.add(text.textSpan!.toPlainText());
    }
  }
  return strings;
}

/// Whether any ancestor paints [element] at effectively zero opacity. The
/// threshold is 1%: nothing legible is deliberately shown below that, and
/// an entrance fade's first frame sits at exactly zero.
bool _hiddenByOpacity(Element element) {
  var hidden = false;
  element.visitAncestorElements((ancestor) {
    final widget = ancestor.widget;
    final opacity = switch (widget) {
      Opacity() => widget.opacity,
      FadeTransition() => widget.opacity.value,
      _ => null,
    };
    if (opacity != null && opacity < 0.01) {
      hidden = true;
      return false;
    }
    return true;
  });
  return hidden;
}

/// Reads [tester]'s visible text, pumps [extraSettlePumps] further bare
/// frames, and fails if that changed anything - unless [knownTransient],
/// the escape hatch for a real, benign transition between two valid loading
/// states (see `ui_snapshot_test.dart`'s own `thread` entry and CLAUDE.md's
/// "how far the mid-flight-capture problem actually spreads" for the one
/// case this is true of today).
///
/// Call this where a caller has decided a surface is settled and is about
/// to treat what is on screen as the real thing - before a snapshot is
/// written, before an overflow assertion is trusted - never afterward, or
/// the extra pumps this runs would let the very drift it looks for slip in
/// ahead of the read.
///
/// [allowNoText] opts a genuinely text-free surface (a pure canvas/graphic)
/// out of the blank check below; every other surface is expected to render
/// at least one string a person reading the screen would see.
///
/// [allowNotFound] is for the one surface that IS the app's not-found page.
Future<void> expectSettled(
  WidgetTester tester,
  String snapshotName, {
  bool knownTransient = false,
  bool allowNoText = false,
  bool allowNotFound = false,
}) async {
  if (!allowNotFound) expectNotNotFound(renderedText(tester), snapshotName);
  final before = renderedText(tester);
  for (var i = 0; i < extraSettlePumps; i++) {
    await tester.pump(extraSettleFrame);
  }
  final after = renderedText(tester);
  if (!knownTransient && !_sameText(before, after)) {
    fail(
      'mid-flight capture: "$snapshotName" still had content resolving when '
      'the settle budget declared it done.\n'
      'captured: $before\n'
      'settled:  $after',
    );
  }
  if (!allowNoText && after.isEmpty) {
    fail(
      'blank capture: "$snapshotName" settled with no visible text at all.\n'
      'A real screen a person reads shows something; pass allowNoText: '
      'true if this surface is genuinely text-free.',
    );
  }
}

/// The router's two not-found pages: go_router's own and the app's.
const _notFoundTexts = ['Page Not Found', 'This page does not exist.'];

/// Fails a capture whose tree is a not-found page: a fixture router missing a
/// route rendered 24 of these as the Dock module surfaces and passed.
void expectNotNotFound(List<String> text, String snapshotName) {
  for (final marker in _notFoundTexts) {
    if (text.contains(marker)) {
      fail(
        'not-found capture: "$snapshotName" rendered the not-found page, so '
        'the surface it names is not in the fixture router.',
      );
    }
  }
}

/// A running readout like a call timer's `1:23` or `673:52:42`. Now that
/// the settle pumps advance real time, a live clock ticking across them is
/// the one text change that IS a correctly settled state rather than a
/// placeholder resolving, so the comparison masks exactly this shape - and
/// nothing else - before deciding.
final _clockPattern = RegExp(r'\d+:\d{2}(?::\d{2})?');

String _withClocksMasked(String s) => s.replaceAll(_clockPattern, '0:00');

bool _sameText(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (_withClocksMasked(a[i]) != _withClocksMasked(b[i])) return false;
  }
  return true;
}
