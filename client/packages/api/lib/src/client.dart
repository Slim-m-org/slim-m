// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The REST client for the slim-m API.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'connection_test.dart';
import 'direct_route.dart';
import 'exceptions.dart';
import 'logging/app_log.dart';
import 'logging/failure.dart';
import 'models.dart';
import 'session_store.dart';
import 'upload_source.dart';

// One tag per file. `part`, not separate libraries: they all reach the
// private transport, and Dart privacy is library-scoped, not file-scoped.
part 'client_admin.dart';
part 'client_attachments.dart';
part 'client_auth.dart';
part 'client_bot_commands.dart';
part 'client_bot_ui.dart';
part 'client_watch_session.dart';
part 'client_channel_admin.dart';
part 'client_canvas.dart';
part 'client_diagnostics.dart';
part 'client_direct_route.dart';
part 'client_dms.dart';
part 'client_dock.dart';
part 'client_emoji.dart';
part 'client_exports.dart';
part 'client_gifs.dart';
part 'client_interactions.dart';
part 'client_join_gate.dart';
part 'client_link_preview.dart';
part 'client_messages.dart';
part 'client_metrics.dart';
part 'client_metrics_parser.dart';
part 'client_moderation.dart';
part 'client_module_commands.dart';
part 'client_module_permissions.dart';
part 'client_module_settings.dart';
part 'client_module_slots.dart';
part 'client_bots.dart';
part 'client_category_permissions.dart';
part 'client_linked_accounts.dart';
part 'client_notification_schedule.dart';
part 'client_presence.dart';
part 'client_push.dart';
part 'client_roles.dart';
part 'client_admin_audit.dart';
part 'client_space.dart';
part 'client_threads.dart';
part 'client_totp.dart';
part 'client_transport.dart';
part 'client_upload_sessions.dart';
part 'client_users.dart';
part 'client_voice.dart';
part 'client_voice_calls.dart';
part 'client_voice_rooms.dart';
part 'client_webhooks.dart';

const _notASlimServer = 'that address is not a slim-m server';

/// A typed client for one server.
///
/// Refresh is handled here rather than by callers: when a request comes back
/// unauthorized and a refresh token is held, the client rotates once and
/// replays the request. Concurrent calls share a single in-flight refresh, so a
/// burst of expired requests does not spend the single-use refresh token more
/// than once (which the server would read as reuse and revoke the session).
class SlimmApi {
  SlimmApi({
    required Uri baseUrl,
    SessionStore? session,
    http.Client? httpClient,
    DirectRoute? directRoute,
  }) : this._(
          baseUrl: baseUrl,
          session: session ?? SessionStore(),
          httpClient: httpClient,
          route:
              directRoute ?? (httpClient == null ? DirectRoute(baseUrl) : null),
        );

  SlimmApi._({
    required this.baseUrl,
    required this.session,
    required http.Client? httpClient,
    required DirectRoute? route,
  })  : _route = route,
        _http = httpClient ?? route?.httpClient ?? http.Client();

  /// The shortcut over the server's own network, when this client owns its
  /// transport; null when a caller handed in an [http.Client].
  final DirectRoute? _route;

  final Uri baseUrl;
  final SessionStore session;

  /// What each refresh reports about this app, so the server's devices list
  /// follows an update instead of the version it signed in with.
  ({String kind, String? version})? clientReport;
  final http.Client _http;

  /// Upload sessions a caller gave up on while they were still resumable,
  /// keyed by the caller's own resume key, so a retry carries on from there.
  final Map<String, String> _resumableUploads = {};

  Future<TokenPair>? _refreshInFlight;

  /// The WebSocket URL for this server, with the scheme mapped from http(s).
  Uri get webSocketUrl {
    final scheme = baseUrl.scheme == 'https' ? 'wss' : 'ws';
    return baseUrl.replace(scheme: scheme, path: '/ws');
  }

  void close() => _http.close();

  /// Whether requests are currently going over the server's own network.
  bool get usesDirectRoute => _route?.active ?? false;

  /// Each change of [usesDirectRoute].
  Stream<bool> get directRouteChanges =>
      _route?.activeChanges ?? const Stream.empty();

  /// Opens the event socket over the same route requests take.
  WebSocketChannel openWebSocket(Uri url) =>
      _route?.connectWebSocket(url) ?? WebSocketChannel.connect(url);

  // --- System ---

  /// What the server says about itself. An address that answers without a
  /// slim-m `/version` (a web page, a 404 or 405 from something else) throws
  /// [NotASlimServerException]; one that does not answer stays a [TransportException].
  Future<Version> version() async {
    try {
      final json = await _send('GET', '/version', authenticated: false);
      return Version.fromJson(json as Map<String, dynamic>);
    } on UnreadableReplyException {
      throw const NotASlimServerException(_notASlimServer);
    } on NotFoundException catch (e) {
      if (!e.unexplained) rethrow;
      throw const NotASlimServerException(_notASlimServer);
    } on ServerException catch (e) {
      if (e.statusCode >= 500) rethrow;
      throw const NotASlimServerException(_notASlimServer);
    } on TypeError {
      throw const NotASlimServerException(_notASlimServer);
    }
  }

  // --- Channels ---

  /// The caller's visible channels. A plain array, unchanged since before
  /// channel categories: the wire is additive-only, and reshaping this
  /// response would break every client that has not updated yet. The
  /// category list is [SlimmApiChannelAdmin.listCategories] instead.
  Future<List<Channel>> listChannels() async {
    final json = await _send('GET', '/channels');
    return (json as List<dynamic>)
        .map((c) => Channel.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Creates a channel. Requires the manage-channels permission, and, only
  /// when [restricted] is true, manage-roles as well - writing the
  /// overwrites a private channel needs is a permissions edit.
  /// [categoryId] files the new channel straight into that rail section.
  /// Null leaves it uncategorised. Naming a category that does not exist is
  /// a 400 rather than a silent fall back, so a stale category id surfaces
  /// instead of quietly putting the channel somewhere nobody chose.
  /// [id] is an optional client-generated UUIDv7 that makes the create
  /// idempotent: a retry with the same id returns the first channel.
  /// [restricted] denies `@everyone` VIEW_CHANNEL and grants only the
  /// caller, written atomically with the channel row itself so it can never
  /// be observed public first. [defaultNotification] is what members get
  /// until they choose their own.
  Future<Channel> createChannel({
    required String name,
    String kind = 'text',
    String? categoryId,
    bool restricted = false,
    bool joinMuted = false,
    NotificationPreference defaultNotification =
        NotificationPreference.everything,
    String? id,
  }) async {
    final json = await _send(
      'POST',
      '/channels',
      body: {
        if (id != null) 'id': id,
        'name': name,
        'kind': kind,
        if (categoryId != null) 'category_id': categoryId,
        if (restricted) 'restricted': true,
        if (joinMuted) 'join_muted': true,
        if (defaultNotification != NotificationPreference.everything)
          'default_notification': defaultNotification.wire,
      },
    );
    return Channel.fromJson(json as Map<String, dynamic>);
  }

  // --- Read state and sync ---

  Future<ReadState> readState(String channelId) async {
    final json = await _send('GET', '/channels/$channelId/read');
    return ReadState.fromJson(json as Map<String, dynamic>);
  }

  /// The caller's marker in every channel they can read, one request instead
  /// of a [readState] per channel. A channel never opened is answered with a
  /// zero marker, so absence means the caller cannot read it.
  Future<List<ChannelReadState>> listReadStates() async {
    final json = await _send('GET', '/read-states');
    return (json as List<dynamic>)
        .map((r) => ChannelReadState.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Advances the read marker. Monotonic: a lower seq is ignored by the server.
  Future<ReadState> markRead({
    required String channelId,
    required int seq,
  }) async {
    final json = await _send(
      'PUT',
      '/channels/$channelId/read',
      body: {'seq': seq},
    );
    return ReadState.fromJson(json as Map<String, dynamic>);
  }

  /// Reads every channel in [channelIds] up to its newest message in one request.
  ///
  /// Channels the caller cannot view are left out of the answer.
  Future<List<ChannelReadState>> markChannelsRead(
    List<String> channelIds,
  ) async {
    final json = await _send(
      'POST',
      '/read-states/read',
      body: {'channel_ids': channelIds},
    );
    return (json as List<dynamic>)
        .map((r) => ChannelReadState.fromJson(r as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Marks a channel unread without moving the read marker.
  ///
  /// The marker is monotonic server-side, so this records an intention beside
  /// it rather than rewinding it. Reading the channel clears it, which means
  /// there is no "mark read again" call to make - [markRead] already does it.
  Future<ReadState> markUnread(String channelId) async {
    final json = await _send('PUT', '/channels/$channelId/unread');
    return ReadState.fromJson(json as Map<String, dynamic>);
  }

  /// Catches several scopes up in one request. Scopes the caller cannot view
  /// are omitted from the response rather than refused.
  Future<List<ScopeDelta>> sync(List<ScopeCursor> scopes) async {
    final json = await _send(
      'POST',
      '/sync',
      body: {'scopes': scopes.map((s) => s.toJson()).toList(growable: false)},
    );
    final map = json as Map<String, dynamic>;
    return (map['scopes'] as List<dynamic>)
        .map((s) => ScopeDelta.fromJson(s as Map<String, dynamic>))
        .toList(growable: false);
  }

  // --- Devices, blocking, private notes, and reporting ---

  /// The account's own devices, with the current one flagged.
  Future<List<Device>> listDevices() async {
    final json = await _send('GET', '/devices');
    return (json as List<dynamic>)
        .map((d) => Device.fromJson(d as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Signs a device out. Its tokens die immediately and its socket is closed.
  Future<void> removeDevice(String deviceId) =>
      _send('DELETE', '/devices/$deviceId', expectNoContent: true);

  /// The users this account has blocked. Blocking is a client-side view filter,
  /// so the caller applies this rather than the server stripping messages.
  Future<List<String>> listBlocks() async {
    final json = await _send('GET', '/blocks');
    return (json as List<dynamic>).cast<String>();
  }

  /// Blocks a user. Idempotent, and the blocked user is never told.
  Future<void> blockUser(String userId) =>
      _send('POST', '/blocks/$userId', expectNoContent: true);

  Future<void> unblockUser(String userId) =>
      _send('DELETE', '/blocks/$userId', expectNoContent: true);

  /// The caller's own private note about [userId], or an all-null [UserNote]
  /// if they have not left one. Never the subject's view of anything: this
  /// can only ever answer for the caller's own note. A subject with nothing
  /// live to answer for - never registered, or since deleted - answers 404,
  /// exactly like [getUser].
  Future<UserNote> getUserNote(String userId) async {
    final json = await _send('GET', '/users/$userId/note');
    return UserNote.fromJson(json as Map<String, dynamic>);
  }

  /// Sets the caller's private note about [userId]. An empty or
  /// whitespace-only [body] clears it rather than storing a blank one, the
  /// same convention [updateMe]'s status text follows.
  Future<UserNote> setUserNote(String userId, String body) async {
    final json = await _send(
      'PUT',
      '/users/$userId/note',
      body: {'body': body},
    );
    return UserNote.fromJson(json as Map<String, dynamic>);
  }

  /// Whether an invite code can be used, and if so, a preview of what it
  /// joins. Unauthenticated, because the person holding a code does not have
  /// an account yet.
  Future<InviteCheck> checkInvite(String code) async {
    final json = await _send(
      'GET',
      '/invites/$code/check',
      authenticated: false,
    );
    return InviteCheck.fromJson(json as Map<String, dynamic>);
  }

  /// Where the landing card's banner for [code] is served, without a session.
  Uri inviteBannerUri(String code) =>
      _requestUri('/invites/$code/banner', null);

  /// Where the landing card's icon for [code] is served, without a session.
  Uri inviteIconUri(String code) => _requestUri('/invites/$code/icon', null);

  /// Spends an invite for the signed-in account.
  Future<void> redeemInvite(String code) =>
      _send('POST', '/invites/$code/redeem', expectNoContent: true);

  /// Files a report for a human to review. [id] is the client-minted UUIDv7
  /// that lets a retry replay the same report instead of colliding with it.
  /// [channelId], [authorId] and [snapshot] go only with
  /// [ReportSubject.ephemeralMessage].
  Future<String> report({
    required ReportSubject subject,
    required String subjectId,
    required String reason,
    String? id,
    String? channelId,
    String? authorId,
    String? snapshot,
  }) async {
    final json = await _send(
      'POST',
      '/reports',
      body: {
        if (id != null) 'id': id,
        'subject_kind': subject.wire,
        'subject_id': subjectId,
        'reason': reason,
        if (channelId != null) 'channel_id': channelId,
        if (authorId != null) 'author_id': authorId,
        if (snapshot != null) 'snapshot': snapshot,
      },
    );
    return (json as Map<String, dynamic>)['id'] as String;
  }
}
