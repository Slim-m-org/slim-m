// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Wire-level bounds a caller needs before sending, not merely after a
/// rejection. [InputLimits] mirrors the server's caps on what a person types,
/// in Unicode code points, the server's unit;
/// `scripts/lib/test_client_input_limits_match_server.py` fails CI when any of
/// them drifts from the Rust constant its doc comment names.
library;

abstract final class InputLimits {
  /// `limits::MAX_NAME_CHARS`: display names, nicknames, channel, category and
  /// role names, webhook labels.
  static const int name = 64;

  /// `limits::MAX_USERNAME_CHARS`.
  static const int username = 32;

  /// `limits::MIN_PASSWORD_CHARS`.
  static const int passwordMin = 8;

  /// `limits::MAX_PASSWORD_CHARS`.
  static const int password = 1024;

  /// `limits::MAX_QUERY_CHARS`: message search and GIF search.
  static const int searchQuery = 200;

  /// `channel_validation::CHANNEL_TOPIC_MAX_CHARS`.
  static const int channelTopic = 256;

  /// `space_landing::MAX_SPACE_DESCRIPTION_CHARS`.
  static const int spaceDescription = 280;

  /// `member_gate::MAX_RULES_CHARS`.
  static const int spaceRules = 4000;

  /// `user_status::STATUS_TEXT_MAX_CHARS`.
  static const int statusText = 80;

  /// `user_status::PRONOUNS_MAX_CHARS`.
  static const int pronouns = 40;

  /// `user_status::ABOUT_MAX_CHARS`.
  static const int about = 190;

  /// `user_notes::MAX_NOTE_CHARS`.
  static const int userNote = 500;

  /// `message_validation::MESSAGE_MAX_CHARS`.
  static const int message = 4000;

  /// `safety::MAX_REASON_CHARS`: report and moderation reasons.
  static const int reportReason = 2000;

  /// `polls::MAX_QUESTION_CHARS`.
  static const int pollQuestion = 300;

  /// `polls::MAX_OPTION_CHARS`.
  static const int pollOption = 100;

  /// `emoji::MAX_NAME_LEN`.
  static const int emojiName = 32;

  /// `roles::ROLE_COLOR_COUNT`: how many colours the role palette holds.
  static const int roleColors = 10;
}

/// What a username may hold, the server's own rule.
final RegExp usernameCharacters = RegExp(r'[A-Za-z0-9_.\-]');

/// Longest a single message's content may be.
const kMessageMaxChars = InputLimits.message;

/// Longest a private user note may be, after trimming.
const kUserNoteMaxChars = InputLimits.userNote;

/// Stated before submit, since the rule was once only ever met as a rejection after the fact.
const kPasswordMinChars = InputLimits.passwordMin;
