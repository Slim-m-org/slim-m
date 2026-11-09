// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Asks for the viewer's own Jellyfin name and password, once per device.
///
/// A short task with a submit, so `showAppSheet`: a bottom sheet on a phone and
/// a centred dialog on a desktop (`docs/design/desktop-vs-mobile.md`, rule 4).
/// The password goes straight to Jellyfin and is never kept; only the token it
/// returns is, in this device's key store. See
/// docs/decisions/0050-watch-party-sync-authority-and-direct-play.md.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/direct_play_controller.dart';

Future<void> showDirectPlaySignIn(
  BuildContext context,
  DirectPlayController controller,
) async {
  final done = await showAppSheet<bool>(
    context,
    semanticLabel: 'Sign in to Jellyfin',
    builder: (context) => _SignIn(controller: controller),
  );
  if (done != true) controller.cancelSignIn();
}

class _SignIn extends StatefulWidget {
  const _SignIn({required this.controller});

  final DirectPlayController controller;

  @override
  State<_SignIn> createState() => _SignInState();
}

/// The part of [baseUrl] that decides who receives the password.
String _hostOf(String baseUrl) {
  final uri = Uri.tryParse(baseUrl);
  if (uri == null || uri.host.isEmpty) return baseUrl;
  return uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
}

class _SignInState extends State<_SignIn> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  late final String? _baseUrl = widget.controller.signInBaseUrl;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy || _name.text.trim().isEmpty || _password.text.isEmpty) return;
    if (widget.controller.signInBaseUrl != _baseUrl) {
      setState(() => _error = 'The server changed. Close this and try again.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.controller.signIn(_name.text.trim(), _password.text);
    if (!mounted) return;
    final error = widget.controller.signInError;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _error = error;
      _password.clear();
    });
  }

  List<Widget> _server(AppTokens tokens, String baseUrl) => [
    Text(
      'Signing in to ${_hostOf(baseUrl)}',
      style: AppText.caption.copyWith(
        color: tokens.textPrimary,
        fontWeight: AppWeights.semi,
      ),
    ),
    if (baseUrl.toLowerCase().startsWith('http://'))
      const AppCallout(
        child: Text('This address is not encrypted. Check it is yours.'),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: AppSpacing.s12,
          children: [
            Text(
              'Sign in to Jellyfin',
              style: AppText.body.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
            Text(
              'Use your own Jellyfin account. The password is not kept.',
              style: AppText.caption.copyWith(color: tokens.textSecondary),
            ),
            if (_baseUrl case final baseUrl?) ..._server(tokens, baseUrl),
            AppInput(
              controller: _name,
              placeholder: 'Jellyfin name',
              autofocus: true,
              autocorrect: false,
              autofillHints: const [AutofillHints.username],
              textInputAction: TextInputAction.next,
            ),
            AppInput(
              controller: _password,
              placeholder: 'Password',
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              errorText: _error,
              onSubmitted: (_) => unawaited(_submit()),
            ),
            AppButton(
              label: 'Sign in',
              full: true,
              busy: _busy,
              onPressed: () => unawaited(_submit()),
            ),
          ],
        ),
      ),
    );
  }
}
