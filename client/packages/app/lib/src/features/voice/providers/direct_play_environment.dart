// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Everything direct play needs from the device, so tests can stand in for it.
library;

import 'package:slimm_api/api.dart' as api;

import 'direct_player.dart';
import 'jellyfin_direct_client.dart';

class DirectPlayEnvironment {
  const DirectPlayEnvironment({
    required this.slimm,
    required this.selfId,
    required this.clock,
    required this.client,
    required this.makePlayer,
    required this.loadCredential,
    required this.saveCredential,
    required this.forgetCredential,
    required this.saveEnabled,
    required this.holdShare,
    required this.releaseShare,
    required this.directPlaySupported,
  });

  final api.SlimmApi slimm;
  final String selfId;
  final DateTime Function() clock;
  final JellyfinDirectClient client;
  final DirectPlayer Function() makePlayer;
  final Future<JellyfinSession?> Function(String baseUrl) loadCredential;
  final Future<void> Function(String baseUrl, JellyfinSession session)
  saveCredential;
  final Future<void> Function(String baseUrl) forgetCredential;
  final Future<void> Function(bool enabled) saveEnabled;
  final void Function(String identity) holdShare;
  final void Function(String identity) releaseShare;

  /// False where the original file cannot be played untranscoded, such as a browser.
  final bool directPlaySupported;
}
