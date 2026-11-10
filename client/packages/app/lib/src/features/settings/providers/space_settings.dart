// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's `/space/settings` object, read once for every row that edits a
/// field of it, so two rows on the same screen do not each fetch it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'settings_actions.dart';

final spaceSettingsProvider = FutureProvider.autoDispose<api.SpaceSettings>(
  (ref) => ref.watch(settingsActionsProvider).spaceSettings(),
);
