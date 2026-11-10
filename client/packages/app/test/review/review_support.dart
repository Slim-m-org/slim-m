// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The review gallery's capture harness: one name scheme, one viewport pair,
/// and the three ways a surface gets on screen (a route, an overlay opened
/// over a route, a standalone widget).
///
/// Every PNG this family writes is `<surface>[--<state>]--<viewport>-<theme>`
/// and lands in `build/ui-snapshots` through `writeSnapshot`, so it exists only
/// under SLIMM_UI_SNAPSHOTS=1. Without it the cases still run and still fail
/// on an overflow, which is the part that belongs in CI. Both themes come from
/// one mount, the way `renderSurfaceThemes` already pays for them.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_design_system/design_system.dart' show MotionOverride;

import '../ui_snapshot_support.dart';

export '../ui_snapshot_support.dart' show loadRealFonts;

/// The gallery's two viewports: a phone, and a desktop window wide enough that
/// the app keeps its desktop layout (a narrower one switches it to touch).
const reviewViewports = {
  'phone': 'phone-portrait',
  'desktop': 'review-desktop',
};

/// The themes every review case captures.
const reviewThemes = ['dark', 'light'];

final _slug = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

String _checked(String part, String label) {
  if (!_slug.hasMatch(part)) {
    throw ArgumentError.value(
      part,
      label,
      'must be lowercase words joined by single hyphens',
    );
  }
  return part;
}

/// `<surface>[--<state>]--<viewport>` without the theme, for test titles.
String reviewTitle(String surface, String? state, String viewport) {
  if (!reviewViewports.containsKey(viewport)) {
    throw ArgumentError.value(viewport, 'viewport', 'must be phone or desktop');
  }
  final head = _checked(surface, 'surface');
  final mid = state == null ? '' : '--${_checked(state, 'state')}';
  return '$head$mid--$viewport';
}

/// The PNG basename (without `.png`) for one capture.
String reviewName(
  String surface,
  String? state,
  String viewport,
  String theme,
) => '${reviewTitle(surface, state, viewport)}-${_checked(theme, 'theme')}';

/// What an [act] or an overlay's `afterOpen` can reach: the container's ref,
/// the router the surface is mounted in, and the navigator's own context (a
/// route-level `showAppSheet` wants one).
///
/// [navigator] is read when asked for: a gate that replaces the whole routed
/// tree leaves no navigator, and an act that only waits for it never asks.
class ReviewHandles {
  const ReviewHandles({required this.ref, required this.router});

  final WidgetRef ref;
  final GoRouter router;

  BuildContext get navigator {
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context == null) {
      throw StateError('the router has no navigator to act on');
    }
    return context;
  }
}

typedef ReviewAct =
    Future<void> Function(WidgetTester tester, ReviewHandles handles);

class _RefHolder {
  WidgetRef? ref;
}

/// A surface at [route] (or in [router]), settled, then driven by [act] before
/// both themes are captured.
///
/// [messages] replaces the fixture transcript. The settle and allow flags go
/// straight to `renderSurfaceThemes`; see its doc. A bad name fails here,
/// before anything is mounted.
Future<void> reviewRoute(
  WidgetTester tester, {
  required String surface,
  String? state,
  required String viewport,
  String route = '/channels/c-general',
  GoRouter? router,
  List<api.Message>? messages,
  List<Override> overrides = const [],
  ReviewAct? act,
  List<String> themes = reviewThemes,
  bool settleNestedResolve = false,
  bool knownTransient = false,
  bool allowNoText = false,
  bool allowNotFound = false,
  bool settleJoinTransition = false,
}) async {
  reviewTitle(surface, state, viewport);
  final appRouter = router ?? fixtureRouter(route);
  final holder = _RefHolder();
  await renderSurfaceThemes(
    tester,
    route,
    reviewViewports[viewport]!,
    themes,
    (theme) => reviewName(surface, state, viewport, theme),
    overrides: overrides,
    settleJoinTransition: settleJoinTransition,
    settleNestedResolve: settleNestedResolve,
    knownTransient: knownTransient,
    allowNoText: allowNoText,
    allowNotFound: allowNotFound,
    router: appRouter,
    messages: messages,
    overlays: [
      Consumer(
        builder: (context, ref, _) {
          holder.ref = ref;
          return const SizedBox.shrink();
        },
      ),
    ],
    afterSettle: act == null
        ? null
        : (tester) =>
              act(tester, ReviewHandles(ref: holder.ref!, router: appRouter)),
  );
}

/// Puts the app in its reduced-motion mode, for a surface whose spinner is the
/// point: an indeterminate spinner's arc follows the clock, so the two themes
/// of one mount would show two different arcs, one of them a bare dash.
Future<void> reduceMotion(WidgetTester tester, ReviewHandles handles) async {
  unawaited(
    handles.ref
        .read(motionPreferenceControllerProvider.notifier)
        .select(MotionOverride.alwaysReduce),
  );
  await tester.pump();
}

/// A sheet, dialog or popover opened over [route], captured while it is up.
///
/// [open] has the signature `support/overlay_registry.dart`'s openers have, so
/// a registry entry replays here in both themes. [afterOpen] runs once the
/// overlay has settled, to type into it or tap something.
Future<void> reviewOverlay(
  WidgetTester tester, {
  required String surface,
  String? state,
  required String viewport,
  String route = '/channels/c-general',
  required FutureOr<void> Function(BuildContext context, WidgetRef ref) open,
  ReviewAct? afterOpen,
  List<Override> overrides = const [],
  List<String> themes = reviewThemes,
}) => reviewRoute(
  tester,
  surface: surface,
  state: state,
  viewport: viewport,
  route: route,
  overrides: overrides,
  themes: themes,
  act: (tester, handles) async {
    unawaited(Future<void>.sync(() => open(handles.navigator, handles.ref)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    if (afterOpen != null) await afterOpen(tester, handles);
  },
);

/// A standalone widget (or a screen the fixture router lacks) as the only
/// route of its own one-route router.
Future<void> reviewWidget(
  WidgetTester tester, {
  required String surface,
  String? state,
  required String viewport,
  required WidgetBuilder build,
  List<Override> overrides = const [],
  ReviewAct? act,
  List<String> themes = reviewThemes,
  bool allowNoText = false,
}) => reviewRoute(
  tester,
  surface: surface,
  state: state,
  viewport: viewport,
  route: '/',
  router: GoRouter(
    routes: [GoRoute(path: '/', builder: (context, _) => build(context))],
  ),
  overrides: overrides,
  act: act,
  themes: themes,
  allowNoText: allowNoText,
);

/// One `testWidgets` per viewport, titled `<name> fits its viewport`, each
/// handing [body] the review viewport label to pass on to a `review*` call.
void reviewCases(
  String surface, {
  String? state,
  List<String> viewports = const ['phone', 'desktop'],
  required Future<void> Function(WidgetTester tester, String viewport) body,
}) {
  for (final viewport in viewports) {
    testWidgets(
      '${reviewTitle(surface, state, viewport)} fits its viewport',
      (tester) => body(tester, viewport),
    );
  }
}
