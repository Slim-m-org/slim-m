// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which part of the sign-in form a failure belongs to, and which failure maps
/// to which part.
///
/// Split out of `sign_in_screen.dart` for that file's line budget, and it is
/// the right seam: this is a pure mapping from a wire failure to a place on
/// screen, with no widget and no state in it.
library;

import 'package:slimm_api/api.dart';

import '../api_failure.dart';

/// Which field a failure lands on, per error grammar 03: an error belongs to
/// the thing that failed, with that thing's content preserved.
/// [SignInErrorField.form] is the fallback for failures no one field owns.
enum SignInErrorField { server, username, displayName, password, form }

/// The longest display name the server accepts, in characters (`validate_label`
/// in the server's `http/auth.rs`).
const displayNameMaxLength = 64;

/// What to tell someone whose display name is past the server's limit, or null.
String? displayNameError(String text) =>
    text.trim().runes.length > displayNameMaxLength
    ? 'Display name must be $displayNameMaxLength characters or fewer.'
    : null;

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
    SignInErrorField.password,
    'Wrong username or password.',
  ),
  ConflictException() => (
    SignInErrorField.username,
    'That username is already taken.',
  ),
  BadRequestException(:final message) => (
    _badRequestField(message),
    sentenceCase(message.replaceFirst('display_name', 'display name')),
  ),
  RateLimitedException() => (
    SignInErrorField.form,
    'Too many attempts just now. Wait a moment and try again.',
  ),
  UnavailableException() => (
    SignInErrorField.form,
    'The server is busy. Try again shortly.',
  ),
  TransportException() => (
    SignInErrorField.server,
    "This Space didn't answer. It may be restarting, or the address may be "
        'wrong. Nothing was sent.',
  ),
  _ => (
    SignInErrorField.form,
    'The server refused that. ${sentenceCase(e.message)}',
  ),
};

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
      'display_name' => SignInErrorField.displayName,
      'password' => SignInErrorField.password,
      _ => SignInErrorField.form,
    };
