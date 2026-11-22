// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the sign-in form knows about the server in its address field.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:slimm_api/api.dart';

import '../widgets/server_identity_chip.dart';
import 'sign_in_server_probe.dart';

/// The screen's side of [SignInProbeController]: closures only, so the
/// controller never holds the widget state.
class SignInProbeHost {
  const SignInProbeHost({
    required this.mounted,
    required this.address,
    required this.ask,
    required this.update,
    required this.onAnswered,
  });

  final bool Function() mounted;

  /// The text currently in the address field.
  final String Function() address;
  final Future<ServerAnswer> Function(String address) ask;

  /// Runs a state change inside the screen's `setState`.
  final void Function(VoidCallback change) update;

  /// Called inside [update] with each applied answer's version.
  final void Function(Version? version) onAnswered;
}

/// Probes the server in the address field, debounced while typing, and keeps
/// the answer, the failure and the identity status that go with it.
class SignInProbeController {
  SignInProbeController(this._host) {
    focusNode.addListener(_onFocus);
  }

  final SignInProbeHost _host;
  final focusNode = FocusNode();
  Timer? _debounce;

  /// What the server in the field said about itself, or null while nothing is
  /// known: the probe is pending, the host is unreachable, or it answered with
  /// something that is not a slim-m `/version`. Every notice below reads from
  /// this, and null renders none of them, because warning someone off a server
  /// that is merely slow to answer is worse than staying quiet.
  Version? probed;

  /// Why the last probe failed; shown only while creating an account, the one
  /// mode that waits on the server answering (see `sign_in_join_steps.dart`).
  String? failure;

  /// How [probed]'s identity compares against whatever this app already
  /// pinned for the address in the field. Read alongside [probed] so the
  /// chip never has to guess a status for an answer it has not seen yet.
  ServerIdentityStatus? identityStatus;

  /// Whether the person asked for this address's answer: on open, Continue, or
  /// leaving the field. The debounced probe while typing keeps a failure quiet.
  bool failureAsked = true;

  /// Asks the server in the field what it is, so the facts worth knowing
  /// before joining are on screen while the choice is still open: whether it
  /// can deliver push at all, whether joining needs an invite, and whether it
  /// offers reporting and blocking.
  ///
  /// The result is applied only if the field still holds the address that was
  /// probed, on every path including failures, so a slow answer about a
  /// previously typed address cannot relabel the current one either way.
  Future<void> probe() async {
    final text = _host.address();
    final answer = await _host.ask(text);
    if (!_host.mounted() || probeTarget(_host.address()) != probeTarget(text)) {
      return;
    }
    _host.update(() {
      probed = answer.version;
      failure = answer.failure;
      identityStatus = answer.status;
      _host.onAnswered(answer.version);
    });
  }

  void cancelDebounce() => _debounce?.cancel();

  /// Forgets the answer, which is about the old address the moment the field
  /// changes; the caller wraps this in its own `setState`.
  void forget() {
    probed = null;
    failure = null;
    identityStatus = null;
    failureAsked = false;
  }

  /// Probes once typing pauses.
  void probeSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), probe);
  }

  void _onFocus() {
    if (!focusNode.hasFocus && !failureAsked) {
      _host.update(() => failureAsked = true);
    }
  }

  void dispose() {
    _debounce?.cancel();
    focusNode.dispose();
  }
}
