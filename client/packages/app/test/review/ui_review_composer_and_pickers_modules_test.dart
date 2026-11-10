// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two sheets a module's apps meet a member in: the app launcher the
/// composer opens, and the "about this module" sheet that says whose it is
/// and what an admin let it do. Dark and light; the PNGs are written only
/// under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';
import 'package:slimm_app/src/features/modules/widgets/app_launcher_sheet.dart';
import 'package:slimm_app/src/features/modules/widgets/module_about_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _watch = api.ModuleInfo(name: 'Watch Party', verified: true);
const _weather = api.ModuleInfo(
  name: 'Weather',
  verified: true,
  capabilities: ['net.fetch', 'kv.store'],
  networkHosts: ['api.open-meteo.com'],
);
const _community = api.ModuleInfo(
  name: 'Standup Helper',
  verified: false,
  capabilities: ['net.fetch', 'message.post', 'kv.store', 'schedule'],
  networkHosts: ['hooks.example.com', 'api.standup.example.org'],
);

const _apps = [
  api.App(
    moduleId: 'watch',
    command: 'open',
    name: 'Watch together',
    description: 'Play a video for everyone in the channel',
    module: _watch,
  ),
  api.App(
    moduleId: 'weather',
    command: 'board',
    name: 'Weather board',
    description: 'Forecasts for the cities you follow',
    module: _weather,
  ),
  api.App(
    moduleId: 'standup',
    command: 'start',
    name: 'Standup',
    description: 'Collect what everyone is working on',
    module: _community,
  ),
];

api.Me _member() => const api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: 0,
  permissions: 6,
);

void _launcher(
  String state,
  List<Override> overrides, {
  ReviewAct? afterOpen,
}) => reviewCases(
  'sheet-app-launcher',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewOverlay(
      tester,
      surface: 'sheet-app-launcher',
      state: state,
      viewport: viewport,
      themes: themes,
      overrides: overrides,
      open: (context, ref) => showAppLauncherSheet(context, ref, 'c-general'),
      afterOpen: afterOpen,
    ),
  ),
);

void _about(String state, api.ModuleInfo module) => reviewCases(
  'sheet-module-about',
  state: state,
  body: (tester, viewport) => reviewShadowed(
    (themes) => reviewOverlay(
      tester,
      surface: 'sheet-module-about',
      state: state,
      viewport: viewport,
      themes: themes,
      open: (context, ref) => showModuleAboutSheet(context, module),
    ),
  ),
);

void main() {
  setUpAll(loadRealFonts);

  _launcher('apps', [appLaunchProvider.overrideWith((ref) async => _apps)]);
  _launcher('empty', [
    appLaunchProvider.overrideWith((ref) async => const <api.App>[]),
  ]);
  _launcher('empty-member', [
    appLaunchProvider.overrideWith((ref) async => const <api.App>[]),
    meProvider.overrideWith((ref) async => _member()),
  ]);
  _launcher('loading', [
    appLaunchProvider.overrideWith((ref) => Completer<List<api.App>>().future),
  ], afterOpen: reduceMotion);
  _launcher('error', [
    appLaunchProvider.overrideWith(
      (ref) => Future<List<api.App>>.error(StateError('offline')),
    ),
  ]);

  _about('verified', _weather);
  _about('community', _community);
  _about('no-powers', const api.ModuleInfo(name: 'Dice', verified: true));
}
