// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dependency wiring.
///
/// One Riverpod container holds everything; there is no second DI mechanism.
/// Providers are written by hand rather than generated so the graph is readable
/// in one file and there is no build step between changing a dependency and
/// running the app.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'database_key_store.dart';
import 'live_events.dart';

/// The server the user picked, with null meaning one has never been picked on
/// this install.
///
/// Split from [serverUrlProvider] because the two answer different questions.
/// "Where does the app point" always has an answer, and a localhost default is
/// a reasonable one. "Has a server ever been chosen" has to be able to say no,
/// and it is the only thing that can tell a first run apart from a returning
/// user who is merely signed out.
class ChosenServer extends Notifier<Uri?> {
  @override
  Uri? build() => null;

  /// The user picked this server. Persisted straight away rather than waiting
  /// for a session to carry it, so an install that chooses a server and never
  /// signs in still knows where it was going on the next launch.
  void choose(Uri server) {
    state = server;
    unawaited(_persist(server));
  }

  /// Read back from storage at launch, so nothing is written: it is already
  /// on disk, and that is where it came from.
  void restore(Uri server) {
    state = server;
  }

  Future<void> _persist(Uri server) async {
    try {
      await ref.read(keyStoreProvider).put(serverUrlHandle, server.toString());
    } catch (_) {
      // Best effort: a key store that refuses to write must not stand between
      // someone and the server they just typed.
    }
  }
}

final chosenServerProvider = NotifierProvider<ChosenServer, Uri?>(
  ChosenServer.new,
);

/// Where the app points. Follows [chosenServerProvider] once a server has been
/// chosen, and falls back to a local default before that. Tests override this
/// directly to aim at a throwaway server.
final serverUrlProvider = Provider<Uri>(
  (ref) =>
      ref.watch(chosenServerProvider) ?? Uri.parse('http://localhost:8080'),
);

/// An invite code chosen during onboarding, redeemed once an account exists.
final pendingInviteProvider = StateProvider<String?>((ref) => null);

/// Set by onboarding right before handing off to sign-in, true only for the
/// compiled-in official server chosen with no invite: the one door besides an
/// invite where arriving here is itself evidence of no account yet, since
/// onboarding only ever runs on an install with no server previously chosen.
/// Consumed and reset the moment sign-in reads it, so a later sign-out on
/// this same server - which skips onboarding entirely - is never mistaken
/// for a fresh join.
final assumeNewAccountProvider = StateProvider<bool>((ref) => false);

/// The handle the persisted session is stored under, in [keyStoreProvider].
const sessionTokenHandle = 'session_token_pair';

/// The handle the chosen server address is stored under.
///
/// It outlives [sessionTokenHandle] deliberately. A session is only meaningful
/// together with the server that issued it, but the reverse is not true: the
/// server someone chose is still the right answer after they sign out, and
/// tying the two together is what used to send a signed-out user back to
/// onboarding to retype an address the app had on disk the whole time.
const serverUrlHandle = 'server_url';

/// The handle for the flag that says this install has launched before. Lives
/// in [preferencesProvider], not [keyStoreProvider]: the point of it is that
/// it does NOT survive an iOS/Android reinstall the way the platform
/// keychain does, so its absence is how [restoreSession] tells a genuinely
/// fresh install apart from an ordinary relaunch.
const hasLaunchedBeforeKey = 'slimm.has_launched_before';

/// Whether [restoreSession] found this install's very first launch (or a
/// wipe indistinguishable from one) this run.
///
/// [hasLaunchedBeforeKey] itself cannot answer this later: by the time
/// anything else reads it, [restoreSession] has already set it to true for
/// every future launch this process or any other ever makes. This provider
/// is the one place that transient fact survives, read once by
/// `WhatsNewController`, which needs the same "was this genuinely fresh"
/// answer to keep a first-ever launch from showing a changelog for updates
/// that happened before the install existed.
final isFreshInstallProvider = StateProvider<bool>((ref) => false);

/// The session, shared by everything that talks to the server so a refresh in
/// one place is seen everywhere.
///
/// Every change is written straight to the key store: a login or a refresh
/// persists the new pair (with the server it belongs to), and a sign-out or a
/// rejected refresh deletes it. [restoreSession] does the other half, reading
/// it back on the next launch.
///
/// Writes are chained, not fired in parallel, inside [SessionStore] itself: a
/// burst of rapid session changes (a restore immediately followed by a
/// refresh) must land on disk in the order they happened, or a slow write can
/// finish after a faster later one and leave a stale value as the persisted
/// state. [SessionStore.settled] is what lets a rotation wait for its own
/// write to land before anything relies on it being durable.
final sessionProvider = Provider<SessionStore>((ref) {
  final keyStore = ref.read(keyStoreProvider);
  final store = SessionStore(
    onChange: (tokens) async {
      final serverUrl = tokens == null ? null : ref.read(serverUrlProvider);
      try {
        await _persistSession(keyStore, tokens, serverUrl);
      } catch (_) {
        /// The server rotates refresh tokens with reuse detection: a write that
        /// failed here may have left a stale, already-spent token on disk, and
        /// replaying that on the next launch reads as reuse and revokes the
        /// whole family. Dropping the stored session outright degrades to a
        /// fresh sign-in instead of that false replay.
        if (tokens != null) {
          await keyStore.delete(sessionTokenHandle).catchError((_) {});
        }
      }
    },
  );
  ref.onDispose(store.dispose);
  return store;
});

Future<void> _persistSession(
  KeyStore keyStore,
  TokenPair? tokens,
  Uri? serverUrl,
) async {
  if (tokens == null) {
    await keyStore.delete(sessionTokenHandle);
    return;
  }
  await keyStore.put(sessionTokenHandle, jsonEncode(tokens.toJson()));
  if (serverUrl != null) {
    await keyStore.put(serverUrlHandle, serverUrl.toString());
  }
}

/// Restores a persisted session from local storage before the router makes
/// its first signed-in/signed-out decision, so a relaunch does not flash
/// sign-in and then jump to channels, and restores the server address that
/// session belongs to in the same step, so a restored session is never left
/// pointed at [serverUrlProvider]'s useless default.
///
/// This only reads local storage, never the network: an access token that
/// turns out to be stale is caught by the same 401-refresh path every other
/// authenticated call already goes through, once the app is on screen and
/// sync or push registration make their first request. Blocking startup on a
/// round trip here would mean a dead connection leaves the user staring at
/// nothing rather than a working, if offline, app.
///
/// Everything here, including the very first read, runs inside the guarded
/// region: main() awaits this before runApp, so any failure of the storage
/// layer itself must degrade to "no stored session" and let the app reach the
/// sign-in screen, never crash launch outright. That guarded region is also
/// where [migrateLegacyFileSecretsIfNeeded] runs, ahead of the reads below:
/// on macOS and Windows an upgrading install's session still sits in the old
/// file until that move lands, and this has to see the moved copy, not miss
/// it and read as signed out.
Future<void> restoreSession(ProviderContainer container) async {
  final keyStore = container.read(keyStoreProvider);
  try {
    await migrateLegacyFileSecretsIfNeeded();

    /// The iOS/Android keychain outlives app deletion; this flag does not, so
    /// its absence means this is the first launch since an install (fresh, or
    /// a reinstall over one that was supposedly wiped). Whatever is already in
    /// the keychain at that point belongs to the account signed in before,
    /// not to this install, and must not come back as if nothing happened.
    ///
    /// That reaches the push key too, and on iOS it takes a second call: a
    /// keychain query carries its own access group and accessibility, so the
    /// wipe below cannot see an item stored under different ones.
    final prefs = await container.read(preferencesProvider.future);
    if (prefs.getBool(hasLaunchedBeforeKey) != true) {
      await keyStore.clear();
      // A second store on iOS; see [pushKeyStoreProvider].
      final pushKeys = container.read(pushKeyStoreProvider);
      if (!identical(pushKeys, keyStore)) await pushKeys.clear();
      await prefs.setBool(hasLaunchedBeforeKey, true);
      container.read(isFreshInstallProvider.notifier).state = true;
      return;
    }

    // Read before the session and restored whether or not there is one: a
    // remembered server is what tells sign-in apart from onboarding.
    final storedServerUrl = await keyStore.read(serverUrlHandle);
    final parsed = storedServerUrl == null
        ? null
        : Uri.tryParse(storedServerUrl);
    final serverUrl =
        parsed != null && parsed.hasScheme && parsed.host.isNotEmpty
        ? parsed
        : null;
    if (serverUrl != null) {
      container.read(chosenServerProvider.notifier).restore(serverUrl);
    }

    final stored = await keyStore.read(sessionTokenHandle);
    if (stored == null) return;

    final tokens = TokenPair.fromJson(
      jsonDecode(stored) as Map<String, dynamic>,
    );

    if (serverUrl == null) {
      // A session with no usable address restores to a connection that can
      // never work, so it is dropped rather than aimed at the default.
      throw const FormatException('missing or invalid persisted server url');
    }

    container.read(sessionProvider).set(tokens);
  } catch (_) {
    // A broken store, corrupt JSON, a missing server address, or anything
    // else here must degrade to "no stored session", never crash launch.
    await keyStore.delete(sessionTokenHandle).catchError((_) {});
  }
}

/// The caller's own profile. Real endpoint; kept here rather than beside one
/// particular widget because more than one of them (the rail footer, the
/// member pane's "message a member" affordance) need to know their own id.
final meProvider = FutureProvider.autoDispose<Me>(
  (ref) => ref.watch(apiProvider).me(),
);

/// [meProvider]'s answer, holding the last one that actually resolved while
/// the connection is down, and refetched when the caller edits their profile
/// somewhere else.
///
/// [meProvider] is fetched once per session. Other people's profiles are kept
/// current by `BatchProfilesController` and `MemberProfileOverridesController`,
/// both watching `ProfileChanged`; nothing watched it for the caller, so a
/// picture or name set on a phone left every other device drawing the old one
/// until it restarted - an avatar is cached under `avatarUpdatedAt`, which
/// only a refetch moves.
///
/// Losing the network made this read as null, and a null `Me` is
/// indistinguishable from a member holding no permissions at all - so the
/// channel rail reshaped itself the moment a phone lost signal: empty
/// categories vanished (they render only for a manager), every row's manage
/// kebab went with them, and the reorderable list collapsed to a plain
/// column. Reported 2026-08-13 as "channels format weird, colors change" when
/// there is no connection to the server.
///
/// Keeping the last resolved answer is safe rather than a shortcut, and
/// `schema/openapi.yaml` already says why: this bitmask is a UI nicety, and
/// the server re-authorizes every write regardless, so a stale-but-real
/// answer can only ever offer an action the server then refuses - where
/// answering null hides actions the caller genuinely holds.
///
/// Cached per user, never across one: a sign-out must not leave the next
/// account looking at whatever the last one could do. The check is on the
/// answer's own id rather than on the fetch having succeeded, because an
/// `AsyncError` keeps whatever value resolved before it - so a failed fetch
/// under a new session still hands back the previous account's `Me`, and
/// only comparing the answer's own id against the session's catches that.
final effectiveMeProvider = NotifierProvider<EffectiveMe, Me?>(EffectiveMe.new);

class EffectiveMe extends Notifier<Me?> {
  String? _forUser;
  Me? _last;

  @override
  Me? build() {
    final userId = ref.watch(sessionProvider).tokens?.userId;
    if (userId != _forUser) {
      _forUser = userId;
      _last = null;
    }
    // Own-profile edits from another device; the two controllers that do this for other people's profiles never covered the caller's own. See this provider's doc.
    final sub = ref.read(liveEventsProvider).listen((event) {
      if (event is ProfileChanged && event.userId == userId) {
        ref.invalidate(meProvider);
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));

    final resolved = ref.watch(meProvider).valueOrNull;
    if (resolved != null && resolved.id == userId) _last = resolved;
    return _last;
  }
}

/// This install's own build: version and build number, read once off the
/// platform. The one source for it in the app; a tester reads it in Personal
/// settings and the rail header names it beside the Space, and both must
/// answer from here rather than each calling [PackageInfo.fromPlatform]
/// itself, or the two could disagree about what build is running.
final appInfoProvider = FutureProvider.autoDispose<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);

/// The API client for the current server.
final apiProvider = Provider<SlimmApi>((ref) {
  final api = SlimmApi(
    baseUrl: ref.watch(serverUrlProvider),
    session: ref.watch(sessionProvider),
  );
  ref.onDispose(api.close);
  return api;
});

/// Builds a throwaway unauthenticated client for a server that is not (yet)
/// the current one: probing a candidate address during onboarding or
/// sign-in. A provider rather than a bare constructor call so tests can
/// substitute a fake transport; the caller owns close().
final probeApiProvider = Provider<SlimmApi Function(Uri)>(
  (ref) =>
      (baseUrl) => SlimmApi(baseUrl: baseUrl),
);

/// The local database. Opened once and closed with the container.
final databaseProvider = FutureProvider<SlimmDatabase>((ref) async {
  final db = SlimmDatabase(
    await openSlimmDatabase(
      keys: KeyStoreDatabaseKey(ref.read(keyStoreProvider)),
      onReset: (reason) =>
          ref.read(databaseResetProvider.notifier).state = reason,
    ),
  );
  ref.onDispose(db.close);
  return db;
});

/// The local store, once the database is open.
final storeProvider = FutureProvider<MessageStore>((ref) async {
  final db = await ref.watch(databaseProvider.future);
  final store = MessageStore(db);
  // Any row still pending belongs to a run that ended; see failInterruptedSends.
  await failInterruptedSends(store);
  return store;
});

/// Ordinary app settings, kept separate from [keyStoreProvider]: nothing
/// stored here is a secret. Today this backs the first-launch flag
/// ([hasLaunchedBeforeKey]), the voice preferences, the appearance choice
/// ([themeChoiceKey]), and the last what's-new version shown
/// (`lastSeenWhatsNewVersionKey`); the first of those is here precisely because
/// this file does NOT survive an iOS/Android reinstall the way the platform
/// keychain does.
final preferencesProvider = FutureProvider<SharedPreferences>(
  (ref) => SharedPreferences.getInstance(),
);

/// The handle the appearance choice is stored under, in [preferencesProvider].
/// Follows the same `slimm.<area>.<thing>` convention as the voice keys.
const themeChoiceKey = 'slimm.appearance.theme';

/// Which colours the app uses.
///
/// [system] is the default, and is what every install has effectively been on
/// since there was no control at all, so nothing changes for a user with
/// nothing stored. It follows the operating system's light/dark setting and
/// deliberately resolves to the ordinary dark palette, never to true black:
/// true black is a choice made for a specific OLED panel, and no OS setting
/// reports one.
enum AppThemeChoice { system, light, dark, trueBlack }

/// The stored appearance choice.
///
/// [restore] is a method main() awaits before `runApp`, rather than a load
/// started from the constructor, because a constructor load resolves a frame
/// or more after the first paint: on a true-black phone that is a white flash
/// before the chosen theme lands.
class ThemeController extends StateNotifier<AppThemeChoice> {
  ThemeController(this._ref) : super(AppThemeChoice.system);

  final Ref _ref;

  /// Reads the stored choice back. A missing or unrecognised value leaves the
  /// default alone, so a preference written by a later version that dropped an
  /// option degrades to following the system rather than throwing.
  Future<void> restore() async {
    try {
      final prefs = await _ref.read(preferencesProvider.future);
      final stored = prefs.getString(themeChoiceKey);
      state = AppThemeChoice.values.firstWhere(
        (choice) => choice.name == stored,
        orElse: () => AppThemeChoice.system,
      );
    } catch (_) {
      // Appearance is not worth failing a launch over, and the default is
      // always a usable answer.
    }
  }

  /// Applies the choice, then persists it. That order is deliberate: the
  /// repaint is immediate and does not wait on storage.
  Future<void> select(AppThemeChoice choice) async {
    state = choice;
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(themeChoiceKey, choice.name);
  }
}

final themeControllerProvider =
    StateNotifierProvider<ThemeController, AppThemeChoice>(ThemeController.new);

/// The runtime probe for what this device can actually do with media. A
/// provider rather than a bare construction, so a test can substitute one
/// backed by a fake seam instead of the real platform.
final mediaCapabilitiesProvider = Provider<MediaCapabilities>(
  (ref) => const MediaCapabilities(),
);

/// Where device secrets live: the session token pair and the push private key
/// today, later signing and agreement keys for E2EE. The platform keychain on
/// iOS and Android, an owner-only-permissioned file on desktop; see
/// `createPersistentKeyStore` for why desktop does not also use the keychain
/// backend.
final keyStoreProvider = Provider<KeyStore>(
  (ref) => createPersistentKeyStore(),
);

/// Where the push private key lives, which on iOS is deliberately not
/// [keyStoreProvider]: the Notification Service Extension has to read that one
/// key from its own process while the phone is locked, and giving it the
/// group every other secret sits in would give it the refresh token too.
///
/// Everywhere else this is [keyStoreProvider] itself rather than a second
/// store over the same storage - see `pushKeyHasItsOwnStore` for why that has
/// to be the same instance - which also means anything overriding the one
/// store in a test still describes the whole picture.
final pushKeyStoreProvider = Provider<KeyStore>(
  (ref) => pushKeyHasItsOwnStore
      ? createPushKeyStore()
      : ref.watch(keyStoreProvider),
);

/// Where a push key an earlier build wrote is still sitting, so the first read
/// after an upgrade moves it rather than orphaning every envelope already
/// sealed to it. Null wherever the key never moved, which is everywhere but
/// iOS; where it did move, the place it moved *from* is exactly the ordinary
/// store.
final legacyPushKeyStoreProvider = Provider<KeyStore?>(
  (ref) => pushKeyHasItsOwnStore ? ref.watch(keyStoreProvider) : null,
);
