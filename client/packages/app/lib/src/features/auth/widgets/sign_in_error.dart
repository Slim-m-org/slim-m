// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which part of the sign-in form a failure belongs to, and which failure maps
/// to which part.
///
/// Split out of `sign_in_screen.dart` for that file's line budget, and it is
/// the right seam: this is a pure mapping from a wire failure to a place on
/// screen, with no widget and no state in it.
library;

import 'package:slimm_api/api.dart';

import '../../../api_failure.dart';

/// Which field a failure lands on, per error grammar 03: an error belongs to
/// the thing that failed, with that thing's content preserved.
/// [SignInErrorField.form] is the fallback for failures no one field owns,
/// and [SignInErrorField.invite] is the code an invite-only Space asks for.
/// [SignInErrorField.credentials] marks both username and password, with the
/// message under the password, because a wrong pair does not say which half.
enum SignInErrorField {
  server,
  invite,
  username,
  password,
  confirmPassword,
  credentials,
  form,
}

/// What to say when something other than the server failed, such as the key store.
const unexpectedSignInError = (
  SignInErrorField.form,
  "Could not sign in. Check this device's secure storage and try again.",
);

/// Where [e] belongs and what to say about it.
///
/// Says what actually happened. "Something went wrong" tells nobody whether to
/// fix their password or wait a minute.
(SignInErrorField, String) signInErrorFor(ApiException e) => switch (e) {
  UnauthorizedException() => (
    SignInErrorField.credentials,
    'Wrong username or password.',
  ),
  ConflictException() => (
    SignInErrorField.username,
    'That username is already taken. If it is yours, sign in instead.',
  ),
  BadRequestException(:final message) => (
    _badRequestField(message),
    sentenceCase(message),
  ),
  RateLimitedException() => (
    SignInErrorField.form,
    'Too many attempts just now. Wait a moment and try again.',
  ),
  UnavailableException() => (
    SignInErrorField.form,
    'The server is busy. Try again shortly.',
  ),
  NotASlimServerException() => notASlimServerError,
  TransportException() => _unreachable,
  _ => (
    SignInErrorField.form,
    'The server refused that. ${sentenceCase(e.message)}',
  ),
};

/// What a host says when it answers, but not as a slim-m server.
const notASlimServerError = (
  SignInErrorField.server,
  'No slim-m server at that address.',
);

const _unreachable = (
  SignInErrorField.server,
  'Could not reach this Space. Check the address, or try again if it is '
      'restarting. Nothing was sent.',
);

const _offline = (
  SignInErrorField.form,
  'This device is offline. Check your connection, then try again. Nothing '
      'was sent.',
);

/// The empty field a submit would send, named before anything goes out.
///
/// [confirmPassword] is the second entry a new account asks for, null otherwise.
(SignInErrorField, String)? missingCredential({
  required String username,
  required String password,
  String? confirmPassword,
}) {
  if (username.trim().isEmpty) {
    return (SignInErrorField.username, 'Enter your username.');
  }
  if (password.isEmpty) {
    return (SignInErrorField.password, 'Enter your password.');
  }
  if (confirmPassword != null && confirmPassword != password) {
    return (SignInErrorField.confirmPassword, 'The passwords do not match.');
  }
  return null;
}

/// A refusal from a server that had just said [username] has an account, so
/// only the password can be wrong. Someone new learns the name is not free.
(SignInErrorField, String) wrongPasswordFor(String username) => (
  SignInErrorField.password,
  'Wrong password for $username. New here? That username is taken.',
);

const _blockedByBrowser = (
  SignInErrorField.server,
  'This Space is up, but the browser blocked the connection. Whoever runs '
      "it has to allow this web app's address (CORS). Nothing was sent.",
);

/// [signInErrorFor], except a failed connection that [reach] still answers is
/// called a browser block when [knownSpace]: an opaque answer could be any site.
/// An [offline] device is told about its own connection instead.
Future<(SignInErrorField, String)> explainSignInFailure(
  ApiException e, {
  required Uri? server,
  required Future<bool?> Function(Uri server) reach,
  required Future<bool> Function(Uri server) knownSpace,
  bool offline = false,
}) async {
  if (e is TransportException && offline) return _offline;
  if (e is! TransportException || server == null) return signInErrorFor(e);
  if (await reach(server) != true) return _unreachable;
  return await knownSpace(server) ? _blockedByBrowser : _unreachable;
}

/// Which field a 400 belongs to.
///
/// The onboarding 400s name the thing that failed as their first word
/// ("username must be 1 to 32 characters", "password must be 8 to 1024
/// characters"), so that word is enough to put the message under the input
/// that caused it rather than in a caption at the foot of the form. Matching
/// the first word rather than the whole string means a reworded rule still
/// lands on the right field; a 400 that names nothing recognisable stays on
/// the form, which is where a failure no one field owns belongs.
SignInErrorField _badRequestField(String message) =>
    switch (message.trimLeft().split(' ').first.toLowerCase()) {
      'username' => SignInErrorField.username,
      'password' => SignInErrorField.password,
      _ => SignInErrorField.form,
    };
