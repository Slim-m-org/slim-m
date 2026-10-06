// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connecting to a server and signing in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../default_server.dart';
import '../providers/providers.dart';
import '../providers/push_controller.dart';
import '../providers/sign_in_identity.dart';
import '../routing/routes.dart';
import '../server_address_reduction.dart';
import '../server_scheme_policy.dart';
import '../widgets/labeled_field.dart';
import '../widgets/onboarding_shell.dart';
import '../widgets/server_identity_confirmation.dart';
import '../widgets/server_notice.dart';
import '../providers/toasts.dart';
import '../providers/whats_new_controller.dart';
import 'reset_password_sheet.dart';
import 'sign_in_alternatives.dart';
import 'sign_in_credential_fields.dart';
import '../widgets/totp_sign_in_prompt.dart';
import 'sign_in_error.dart';
import 'sign_in_invite_notice.dart';
import 'sign_in_invite_redeem.dart';
import 'sign_in_session_ended_notice.dart';

/// Sign in or create an account on a chosen server.
///
/// The server address is part of this screen rather than buried in settings,
/// because self-hosting is the normal case: which server you are on is a
/// first-class choice, not an advanced option. The one exception is the
/// compiled-in official server, where that choice was already made by
/// picking "Join the official Space" in onboarding: the field stays
/// collapsed so joining it is username and password, nothing else, and
/// "Use a different Space" leads back to onboarding for any other address. It also opens straight on creating an account,
/// for the same reason an invite does: that button means there is no
/// account here yet.
///
/// Collapsed is not silent about the destination. The identity chip used to
/// sit inside the branch that draws the address field, so the official-server
/// path - the commonest way in, and the one that deliberately hides that
/// field - named no server anywhere on screen. It is outside that branch now,
/// with a quieter line standing in until the probe answers, so every state of
/// this screen says where it is about to connect.
class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});

  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> {
  /// Prefilled from the server chosen during onboarding, which every entry path
  /// has already written; a hardcoded default here silently overrode that
  /// choice on submit.
  late final TextEditingController _server = TextEditingController(
    text: ref.read(serverUrlProvider).toString(),
  );

  /// Whether the address field is on screen. Collapsed for the compiled-in
  /// official server, where an address is not a decision anyone joining it
  /// needs to make; a different address is chosen through onboarding.
  late final bool _addressExpanded = !isOfficialServer(
    ref.read(serverUrlProvider),
  );
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _displayName = TextEditingController();

  bool _creatingAccount = false;

  /// Set once the person picks a mode, so a late probe never switches it.
  bool _modeChosen = false;
  bool _busy = false;

  /// The current failure and the field it belongs to; see [signInErrorFor].
  (SignInErrorField, String)? _error;

  String? _errorFor(SignInErrorField field) =>
      _error?.$1 == field ? _error!.$2 : null;

  /// What the server in the field said about itself, or null while nothing is
  /// known: the probe is pending, the host is unreachable, or it answered with
  /// something that is not a slim-m `/version`. Every notice below reads from
  /// this, and null renders none of them, because warning someone off a server
  /// that is merely slow to answer is worse than staying quiet.
  Version? _probed;
  Timer? _probeDebounce;

  /// How [_probed]'s identity compares against whatever this app already
  /// pinned for the address in the field. Read alongside [_probed] so the
  /// chip never has to guess a status for an answer it has not seen yet.
  ServerIdentityStatus? _identityStatus;

  @override
  void initState() {
    super.initState();
    // An invite or "Join the official Space" means no account here yet, so open on creating one.
    // The flag is consumed after this build so a later sign-out on this address starts on "Sign in".
    final assumedNew = ref.read(assumeNewAccountProvider);
    if (assumedNew) {
      // A provider cannot be written mid-build; this runs right after it, guarded because a screen disposed before that turn leaves the flag stale true, at worst opening a later visit on "Create an account" - recoverable via the toggle below.
      Future(() {
        if (!mounted) return;
        ref.read(assumeNewAccountProvider.notifier).state = false;
      });
    }
    _creatingAccount = ref.read(pendingInviteProvider) != null || assumedNew;
    _probeServer();
  }

  @override
  void dispose() {
    _probeDebounce?.cancel();
    _server.dispose();
    _username.dispose();
    _password.dispose();
    _displayName.dispose();
    super.dispose();
  }

  /// One wording, shared by sign-in and recovery, so the two doors onto the
  /// same field cannot drift apart.
  void _badAddress() => setState(
    () => _error = (
      SignInErrorField.server,
      'That does not look like a server address.',
    ),
  );

  /// Reduces a typed address to the scheme, host, and port worth probing.
  /// Anything else it carries (path, query, userinfo) must not ride along
  /// on a request that fires as someone types: pasted userinfo would even
  /// become a Basic auth header sent to whatever host is in the field.
  Uri? _probeTarget(String text) {
    final parsed = Uri.tryParse(text.trim());
    if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
      return null;
    }
    return reduceServerAddress(parsed);
  }

  /// How [identity] compares against whatever is pinned for [target], for
  /// the passive chip only: read-only, no pinning and no navigation. The
  /// active check that pins and can block a connection lives in [_submit],
  /// via [confirmServerIdentity].
  Future<ServerIdentityStatus> _identityStatusFor(
    Uri target,
    ServerIdentity? identity,
  ) async {
    if (identity == null) return ServerIdentityStatus.unknown;
    final pinned = await ref
        .read(keyStoreProvider)
        .read(identityHandleFor(target));
    if (pinned == null) return ServerIdentityStatus.unknown;
    return pinned == identity.publicKey
        ? ServerIdentityStatus.confirmed
        : ServerIdentityStatus.mismatch;
  }

  /// Asks the server in the field what it is, so the facts worth knowing
  /// before joining are on screen while the choice is still open: whether it
  /// can deliver push at all, whether joining needs an invite, and whether it
  /// offers reporting and blocking.
  ///
  /// Every failure resolves to "unknown". A host that answers 200 with
  /// something that is not a slim-m `/version` body is as unknown as one that
  /// refuses to connect, so the bare `catch` is deliberate: a foreign or
  /// hostile server must not crash sign-in with a shaped reply.
  ///
  /// The result is applied only if the field still holds the address that was
  /// probed, on every path including failures, so a slow answer about a
  /// previously typed address cannot relabel the current one either way.
  Future<void> _probeServer() async {
    final target = _probeTarget(_server.text);
    if (target == null) {
      setState(() {
        _probed = null;
        _identityStatus = null;
      });
      return;
    }
    final client = ref.read(probeApiProvider)(target);
    Version? answer;
    try {
      answer = await client.version();
    } on ApiException {
      // Unreachable or refusing means unknown, and sign-in itself will say
      // "could not reach that server" with more authority than a probe.
      answer = null;
    } catch (_) {
      // A shaped reply from a foreign host is as unknown as a refusal.
      answer = null;
    } finally {
      client.close();
    }
    final status = await _identityStatusFor(target, answer?.identity);
    if (!mounted) return;
    if (_probeTarget(_server.text) == target) {
      setState(() {
        _probed = answer;
        _identityStatus = status;
        if (answer?.claimed == false && !_modeChosen) _creatingAccount = true;
      });
    }
  }

  /// The host in the field, for naming the destination on screen. Falls back
  /// to the raw text so a half-typed address still shows what it is rather
  /// than going blank mid-keystroke.
  String _host() {
    final host = Uri.tryParse(_server.text.trim())?.host ?? '';
    return host.isEmpty ? _server.text.trim() : host;
  }

  bool _targetsOfficial() {
    final target = _probeTarget(_server.text);
    return target != null && isOfficialServer(target);
  }

  void _onServerEdited(String _) {
    // The old answer is about the old address the moment the field changes,
    // and the line naming the destination is read off the field itself.
    setState(() {
      _probed = null;
      _identityStatus = null;
    });
    _probeDebounce?.cancel();
    _probeDebounce = Timer(const Duration(milliseconds: 600), _probeServer);
  }

  /// The reset-code flow, which confirms identity the way [_submit] does and
  /// hands back no session - hence "sign in", rather than signing them in.
  Future<void> _recoverAccount() async {
    final done = await startAccountRecovery(
      context,
      ref,
      _probeTarget(_server.text),
    );
    if (done == null) {
      _badAddress();
      return;
    }
    if (!done || !mounted) return;
    ref
        .read(toastsProvider.notifier)
        .show(
          'Password set. Sign in with your new password.',
          severity: AppToastSeverity.success,
        );
  }

  /// Signs in or registers, then starts push.
  ///
  /// On registration the invite code goes in with the signup rather than being
  /// redeemed after it: a claimed deployment refuses an uninvited registration
  /// outright, so there is no account to redeem against until that call
  /// succeeds.
  ///
  /// Sync is deliberately not started here. `SyncController` is session-driven
  /// (see its class doc) and its own listener already reacts to the
  /// `session.set()` that register or login just performed. Starting it again
  /// explicitly raced that listener and opened a second socket, which went on
  /// to kick the first, healthy one offline.
  ///
  /// Push registration is fire-and-forget: a denied permission or unreachable
  /// server must never hold up a sign-in that is already complete.
  ///
  /// The address is reduced and its identity confirmed before anything is
  /// persisted or sent: this is "connecting", in the sense
  /// [confirmServerIdentity] means it, and binding the check here (rather
  /// than to the field being typed) is what makes a returning sign-in - not
  /// only the manual onboarding dialog - a place TOFU's comparison runs.
  ///
  /// A first connect to the compiled-in official address pins silently, for
  /// the reason onboarding's own official button documents: there is no
  /// separate operator to read a fingerprint to, so the question has no answer.
  /// This door onto that address used to ask anyway. A key that later changes
  /// is never silent either way, which is the case the check exists for.
  Future<void> _submit() async {
    final address = Uri.tryParse(_server.text.trim());
    if (address == null || !address.hasScheme || address.host.isEmpty) {
      _badAddress();
      return;
    }

    if (requireSecureScheme(address) case final schemeError?) {
      setState(() => _error = (SignInErrorField.server, schemeError));
      return;
    }

    if (_creatingAccount && !_targetsOfficial()) {
      if (displayNameError(_displayName.text) case final tooLong?) {
        setState(() => _error = (SignInErrorField.displayName, tooLong));
        return;
      }
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final invite = ref.read(pendingInviteProvider);
    // Read before the awaits: the session redirect can dispose this screen mid-flight.
    final pendingInvite = ref.read(pendingInviteProvider.notifier);
    final justRegistered = ref.read(justRegisteredProvider.notifier);
    final push = ref.read(pushControllerProvider.notifier);
    try {
      final reduced = reduceServerAddress(address);
      // Silent for the compiled-in address; see this method's own doc.
      if (!await confirmServerIdentity(
        context,
        ref,
        reduced,
        silentFirstConnect: isOfficialServer(reduced),
      )) {
        return;
      }
      if (!mounted) return;

      ref.read(chosenServerProvider.notifier).choose(reduced);
      final api = ref.read(apiProvider);
      final identity = await signInIdentity(
        keyStore: ref.read(keyStoreProvider),
        appInfo: ref.read(appInfoProvider.future),
      );

      if (_creatingAccount) {
        // Before the call: its session change is what starts the what's-new check.
        justRegistered.state = true;
        await api.register(
          username: _username.text.trim(),
          displayName: _displayName.text.trim().isEmpty
              ? _username.text.trim()
              : _displayName.text.trim(),
          password: _password.text,
          deviceName: identity.deviceName,
          inviteCode: invite,
          clientKind: identity.clientKind,
          clientVersion: identity.clientVersion,
          installId: identity.installId,
        );
      } else {
        final outcome = await api.login(
          username: _username.text.trim(),
          password: _password.text,
          deviceName: identity.deviceName,
          clientKind: identity.clientKind,
          clientVersion: identity.clientVersion,
          installId: identity.installId,
        );
        // No session yet, so nothing below may run until one exists; abandoning the sheet leaves the screen as it was.
        if (outcome case SignInChallenged(:final challenge)) {
          if (!mounted) return;
          final signedIn = await promptForTotpCode(
            context,
            ref,
            challenge,
            installId: identity.installId,
          );
          if (!signedIn) return;
        }
        // An existing account can still spend a code, for the role it grants.
        if (invite != null) await redeemInviteQuietly(api, invite);
      }
      if (invite != null) pendingInvite.state = null;
      unawaited(push.register());
    } on ApiException catch (e) {
      justRegistered.state = false;
      if (!mounted) return;
      setState(() => _error = signInErrorFor(e));
    } catch (_) {
      ref.read(justRegisteredProvider.notifier).state = false;
      if (mounted) setState(() => _error = unexpectedSignInError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;

    return OnboardingShell(
      // Creating an account is the last of the join steps; signing back in to
      // a server you already trust is one act and gets no stepper.
      step: _creatingAccount ? OnboardingStep.identity : null,
      version: ref.watch(appInfoProvider).valueOrNull?.version,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _creatingAccount ? 'Create an account' : 'Welcome back',
            style: AppText.title.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          const SizedBox(height: AppSpacing.s8),
          // Where this is about to connect, on both branches; see the class doc.
          if (_probed case final version?)
            ServerIdentityChip(
              spaceName: version.name,
              host: _host(),
              status: _identityStatus ?? ServerIdentityStatus.unknown,
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: AppSpacing.s16),
              child: Text(
                'Connecting to ${_host()}',
                style: AppText.code.copyWith(color: tokens.textSecondary),
              ),
            ),
          const SessionEndedNotice(),
          if (_addressExpanded) ...[
            LabeledField(
              label: 'Server',
              helper: "The Space you're joining - its server address.",
              child: AppInput(
                controller: _server,
                mono: true,
                errorText: _errorFor(SignInErrorField.server),
                keyboardType: TextInputType.url,
                autocorrect: false,
                semanticLabel: 'Server',
                onChanged: _onServerEdited,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
          ],
          // First of the three: the other two are about convenience,
          // this one is about whether you have any recourse here.
          if (_probed case final version?) ServerSafetyNotice(version: version),
          if (_creatingAccount && _probed != null)
            InviteRequiredNotice(version: _probed!),
          if (_probed?.pushEnabled == false)
            const ServerNotice(
              icon: AppIcons.notificationsOff,
              message:
                  'This Space cannot send push notifications. '
                  'You can still use it, but phones will only see '
                  'new messages while the app is open.',
            ),
          const SizedBox(height: AppSpacing.s16),
          SignInCredentialFields(
            username: _username,
            displayName: _displayName,
            password: _password,
            creatingAccount: _creatingAccount,
            askDisplayName: !_targetsOfficial(),
            busy: _busy,
            errorFor: _errorFor,
            onSubmit: _submit,
            onRecoverAccount: () => unawaited(_recoverAccount()),
          ),
          if (_errorFor(SignInErrorField.form) case final formError?) ...[
            const SizedBox(height: AppSpacing.s16),
            Semantics(
              liveRegion: true,
              child: Text(
                formError,
                style: AppText.caption.copyWith(color: tokens.dangerText),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.s24),
          AppButton(
            label: _creatingAccount ? 'Create account' : 'Sign in',
            variant: AppButtonVariant.primary,
            size: AppButtonSize.lg,
            full: true,
            busy: _busy,
            onPressed: _submit,
          ),
          const SizedBox(height: AppSpacing.s12),
          // Alternatives to the action above, not a list under it.
          SignInAlternatives(
            creatingAccount: _creatingAccount,
            busy: _busy,
            onToggleCreating: () => setState(() {
              _creatingAccount = !_creatingAccount;
              _modeChosen = true;
              _error = null;
            }),
            onUseDifferentSpace: () => context.go(Routes.onboarding),
          ),
        ],
      ),
    );
  }
}
