// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The caller's linked accounts, and the pieces the Connections section needs
/// around them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import '../../../external_link.dart';
import '../../../providers/providers.dart';

/// What the caller has linked, refetched when invalidated.
final myLinkedAccountsProvider =
    FutureProvider.autoDispose<List<api.LinkedAccount>>(
      (ref) => ref.watch(apiProvider).myLinkedAccounts(),
    );

/// Set once the server answers 501 to a link start: it has no Discord app.
final discordLinkUnavailableProvider = StateProvider<bool>((ref) => false);

/// Where the authorize URL opens; replaced in tests.
final externalUrlLauncherProvider = Provider<ExternalUrlLauncher>(
  (ref) => defaultExternalUrlLauncher,
);
