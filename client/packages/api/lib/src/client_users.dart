// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Most ids `GET /users` takes in one request; mirrors `MAX_USER_BATCH` in
/// `crates/slimm-server/src/http/users.rs`, which answers 400 past it.
const _maxUserIdsPerRequest = 100;

/// Profiles, the caller's own account, and the deployment's member list: the
/// `users` tag in schema/openapi.yaml.
extension SlimmApiUsers on SlimmApi {
  /// The caller's own profile and base (deployment-level) permissions.
  Future<Me> me() async {
    final json = await send('GET', '/me');
    return Me.fromJson(json as Map<String, dynamic>);
  }

  /// Updates the caller's own profile fields. Every field is optional, null
  /// meaning "leave it as it is" - a call naming none of them throws a 400.
  /// Pass an empty string for [statusText]/[pronouns]/[about] to clear it
  /// back to none, the same "blank clears it" convention `updateChannel`'s
  /// `topic` uses. [profileColor] has no clearing case: every account always
  /// has one; sending it without [profileColorRgb] drops a custom colour. The username is not editable here: it backs the live
  /// per-account uniqueness index, so changing it needs a dedicated flow that
  /// can handle the resulting collision.
  Future<UserProfile> updateMe({
    String? displayName,
    String? statusText,
    String? pronouns,
    String? about,
    int? profileColor,
    int? profileColorRgb,
  }) async {
    final json = await send(
      'PATCH',
      '/me',
      body: {
        if (displayName != null) 'display_name': displayName,
        if (statusText != null) 'status_text': statusText,
        if (pronouns != null) 'pronouns': pronouns,
        if (about != null) 'about': about,
        if (profileColor != null) 'profile_color': profileColor,
        if (profileColorRgb != null) 'profile_color_rgb': profileColorRgb,
      },
    );
    return UserProfile.fromJson(json as Map<String, dynamic>);
  }

  /// Batch-fetches public profiles by id. An id with nothing live to report
  /// (never existed, or deleted) is simply absent from the result, so match
  /// by id rather than by position.
  ///
  /// More than the server's per-request cap is split across requests, which
  /// the server would otherwise refuse outright with a 400.
  Future<List<UserProfile>> listUsers(List<String> ids) async {
    final unique = ids.toSet().toList(growable: false);
    final pages = [
      for (var i = 0; i < unique.length; i += _maxUserIdsPerRequest)
        unique.sublist(
          i,
          i + _maxUserIdsPerRequest > unique.length
              ? unique.length
              : i + _maxUserIdsPerRequest,
        ),
    ];
    final answers = await Future.wait(pages.map(_listUsersPage));
    return [for (final page in answers) ...page];
  }

  Future<List<UserProfile>> _listUsersPage(List<String> ids) async {
    final json = await send('GET', '/users', query: {'ids': ids.join(',')});
    return (json as List<dynamic>)
        .map((u) => UserProfile.fromJson(u as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// A single public profile. A deleted or anonymized account answers 404,
  /// exactly like an id that was never used, so this cannot confirm someone
  /// deleted their account.
  Future<UserProfile> getUser(String userId) async {
    final json = await send('GET', '/users/$userId');
    return UserProfile.fromJson(json as Map<String, dynamic>);
  }

  /// The deployment's members, oldest first. Deployment-wide rather than
  /// scoped to a channel, so any authenticated caller may read it. Keyset
  /// paginated on id; pass the last id seen as [after] for the next page.
  ///
  /// [channel] narrows the page to who can view that channel, for a member
  /// list shown beside it. It is a display filter, not a confidentiality
  /// boundary - the unfiltered roster stays readable from this same route -
  /// and it does not change paging: a page shorter than [limit] is still the
  /// last one.
  Future<List<UserProfile>> listMembers({
    String? after,
    int? limit,
    String? channel,
  }) async {
    final query = <String, String>{
      if (after != null) 'after': after,
      if (limit != null) 'limit': '$limit',
      if (channel != null) 'channel': channel,
    };
    final json = await send(
      'GET',
      '/members',
      query: query.isEmpty ? null : query,
    );
    return (json as List<dynamic>)
        .map((u) => UserProfile.fromJson(u as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Uploads (or replaces) the caller's avatar with raw [bytes]. One mutable
  /// image per user, replaced wholesale: unlike [SlimmApi.uploadAttachment]
  /// this is never content-addressed and no channel permission gates it.
  Future<UserProfile> uploadAvatar(List<int> bytes) async {
    final json = await send('POST', '/me/avatar', bytes: bytes);
    return UserProfile.fromJson(json as Map<String, dynamic>);
  }

  /// Removes the caller's avatar. Not an error if there was none.
  Future<void> deleteAvatar() =>
      send('DELETE', '/me/avatar', expectNoContent: true);

  /// Fetches a user's avatar bytes. Gated on authentication only: an avatar
  /// is a public profile picture, not a message attachment, so no channel
  /// permission applies.
  Future<FetchedBytes> fetchAvatar(String userId) =>
      fetchBytes('/users/$userId/avatar');

  /// Uploads (or replaces) the caller's profile banner, an image or a gif.
  Future<UserProfile> uploadBanner(List<int> bytes) async {
    final json = await send('POST', '/me/banner', bytes: bytes);
    return UserProfile.fromJson(json as Map<String, dynamic>);
  }

  /// Removes the caller's banner, so the profile colour shows again.
  Future<void> deleteBanner() =>
      send('DELETE', '/me/banner', expectNoContent: true);

  /// Fetches a user's banner bytes; 404 for a user with none.
  Future<FetchedBytes> fetchBanner(String userId) =>
      fetchBytes('/users/$userId/banner');
}
