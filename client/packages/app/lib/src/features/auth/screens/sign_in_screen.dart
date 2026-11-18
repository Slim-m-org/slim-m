// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connecting to a server and signing in.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show TextInput;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../first_run/providers/first_run_controller.dart'
    show firstRunInviterProvider;
import '../../../default_server.dart';
import '../../../providers/providers.dart';
import '../../../push/providers/push_controller.dart';
import '../providers/browser_reach.dart';
import '../providers/sign_in_identity.dart';
import '../../../routing/routes.dart';
import '../../../server_address_reduction.dart';
import '../../../widgets/labeled_field.dart';
import '../widgets/onboarding_shell.dart';
import '../widgets/server_identity_confirmation.dart';
import '../../../widgets/server_notice.dart';
import '../../../providers/toasts.dart';
import '../../../whats_new/providers/whats_new_controller.dart';
import 'reset_password_sheet.dart';
import 'sign_in_alternatives.dart';
import '../widgets/sign_in_credential_fields.dart';
import '../widgets/server_warnings_modal.dart';
import '../widgets/sign_in_error.dart';
import '../../../invite_link.dart';
import 'invite_code_check.dart';
import 'sign_in_destination.dart';
import 'sign_in_invite_notice.dart';
import 'sign_in_join_steps.dart';
import 'sign_in_register.dart';
import 'sign_in_server_probe.dart';
import 'sign_in_reason_notices.dart';

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
/// Creating an account opens in steps (`sign_in_join_steps.dart`), and every
/// state names where it is about to connect (`sign_in_destination.dart`).
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

  bool _creatingAccount = false;

  /// Set once the person picks a mode, so a late probe never switches it.
  bool _modeChosen = false;
  bool _busy = false;

  /// The current failure and the field it belongs to; see [signInErrorFor].
  (SignInErrorField, String)? _error;

  /// A wrong username/password pair lands on the password, as does its own error.
  String? _errorFor(SignInErrorField field) =>
      _error?.$1 == field ||
          (field == SignInErrorField.password &&
              _error?.$1 == SignInErrorField.credentials)
      ? _error!.$2
      : null;

  /// What the server in the field said about itself, or null while nothing is
  /// known: the probe is pending, the host is unreachable, or it answered with
  /// something that is not a slim-m `/version`. Every notice below reads from
  /// this, and null renders none of them, because warning someone off a server
  /// that is merely slow to answer is worse than staying quiet.
  Version? _probed;
  Timer? _probeDebounce;

  /// Why the last probe failed; shown only while creating an account, the one
  /// mode that waits on the server answering (see `sign_in_join_steps.dart`).
  String? _probeFailure;

  late final _invite = HeldInvite(
    pending: ref.read(pendingInviteProvider),
    server: probeTarget(_server.text),
  );

  JoinStage get _stage => joinStageFor(
    creatingAccount: _creatingAccount,
    probed: _probed,
    inviteAccepted: _invite.acceptedFor(probeTarget(_server.text)),
  );

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
    _invite.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Asks the server in the field what it is, so the facts worth knowing
  /// before joining are on screen while the choice is still open: whether it
  /// can deliver push at all, whether joining needs an invite, and whether it
  /// offers reporting and blocking.
  ///
  /// The result is applied only if the field still holds the address that was
  /// probed, on every path including failures, so a slow answer about a
  /// previously typed address cannot relabel the current one either way.
  Future<void> _probeServer() async {
    // An address the form would refuse to submit must not open the steps after it.
    final (address, problem) = submittableAddress(_server.text);
    if (address == null) {
      setState(() {
        _probed = null;
        _probeFailure = problem;
        _identityStatus = null;
      });
      return;
    }
    final target = reduceServerAddress(address);
    final keyStore = ref.read(keyStoreProvider);
    final probe = await probeServerVersion(
      ref.read(probeApiProvider)(target),
      target,
      // Only the create form says why a probe failed, so only it asks the browser.
      reach: _creatingAccount
          ? ref.read(browserReachProbeProvider)
          : (_) async => null,
      knownSpace: pinnedIdentityCheck(keyStore),
    );
    if (!mounted) return;
    final answer = probe.version;
    final status = await identityStatusFor(keyStore, target, answer?.identity);
    if (!mounted || probeTarget(_server.text) != target) return;
    setState(() {
      _probed = answer;
      _probeFailure = probe.failure;
      _identityStatus = status;
      if (answer?.claimed == false && !_modeChosen) _creatingAccount = true;
    });
  }

  /// Continue before the address has answered checks it now, without the debounce.
  Future<void> _checkServer() async {
    _probeDebounce?.cancel();
    if (_submittableAddress() == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    await _probeServer();
    if (mounted) setState(() => _busy = false);
  }

  /// Checks the code on the server in the field before any account field opens.
  Future<void> _checkInvite() async {
    final address = _submittableAddress();
    if (address == null) return;
    final target = reduceServerAddress(address);
    final code = _invite.controller.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    final problem = await inviteCodeProblem(
      ref.read(probeApiProvider)(target),
      code,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (problem != null) _error = (SignInErrorField.invite, problem);
      if (problem == null) _invite.accept(target, code);
    });
  }

  /// A whole invite link fills both fields, as it does in the invite dialog;
  /// the server it names is probed like a typed one.
  void _onInviteEdited(String text) {
    if (parseInviteLink(text) case (:final server, :final code)) {
      _invite.controller.text = code;
      if (probeTarget(server.toString()) != probeTarget(_server.text)) {
        _server.text = server.toString();
        _onServerEdited(_server.text);
        unawaited(_checkServer());
      }
    }
    setState(() {
      if (_error?.$1 == SignInErrorField.invite) _error = null;
    });
  }

  void _onServerEdited(String _) {
    // The old answer is about the old address the moment the field changes,
    // and the line naming the destination is read off the field itself.
    setState(() {
      _probed = null;
      _probeFailure = null;
      _identityStatus = null;
      if (_error?.$1 == SignInErrorField.server) _error = null;
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
      probeTarget(_server.text),
    );
    if (done == null) {
      _submittableAddress();
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
  /// A first connect pins silently; a key that later changes is the case the
  /// check exists for.
  Future<void> _submit() async {
    final address = _submittableAddress();
    if (address == null) return;
    if (_creatingAccount && !await _acknowledgedWarnings()) return;
    if (!mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    final invite = _invite.codeFor(probeTarget(_server.text));
    // Read before the awaits: the session redirect can dispose this screen mid-flight.
    final pendingInvite = ref.read(pendingInviteProvider.notifier);
    final justRegistered = ref.read(justRegisteredProvider.notifier);
    final push = ref.read(pushControllerProvider.notifier);
    final firstContact = ref.read(firstContactServersProvider.notifier);
    try {
      final reduced = reduceServerAddress(address);
      if (!await confirmServerIdentity(
        context,
        ref,
        reduced,
        requireSlimServer: true,
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

      final credentials = (
        username: _username.text.trim(),
        password: _password.text,
      );
      if (_creatingAccount) {
        await registerAccount(
          api,
          identity,
          justRegistered: justRegistered,
          inviter: ref.read(firstRunInviterProvider.notifier),
          credentials: credentials,
          invite: invite,
        );
      } else if (!mounted ||
          !await signInToAccount(
            context,
            ref,
            api,
            identity,
            credentials: credentials,
            invite: invite,
          )) {
        return;
      }
      endFirstContact(firstContact, reduced);
      TextInput.finishAutofillContext();
      pendingInvite.state = null;
      unawaited(push.register());
    } on ApiException catch (e, stack) {
      reportFailure(LogTag.auth, 'sign in', e, stack);
      justRegistered.state = false;
      if (!mounted) return;
      final error = await explainSignInFailure(
        e,
        server: probeTarget(_server.text),
        reach: ref.read(browserReachProbeProvider),
        knownSpace: pinnedIdentityCheck(ref.read(keyStoreProvider)),
      );
      if (!mounted) return;
      setState(() => _error = error);
    } catch (error, stack) {
      reportFailure(LogTag.auth, 'sign in', error, stack);
      ref.read(justRegisteredProvider.notifier).state = false;
      if (mounted) setState(() => _error = unexpectedSignInError);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The typed address when it can be submitted; otherwise shows why not.
  Uri? _submittableAddress() {
    final (address, problem) = submittableAddress(_server.text);
    if (problem != null) {
      setState(() => _error = (SignInErrorField.server, problem));
    }
    return address;
  }

  /// Joining is where server warnings matter; signing in never asks.
  Future<bool> _acknowledgedWarnings() {
    final warnings = serverWarningsFor(_probed);
    if (warnings.isEmpty) return Future.value(true);
    return confirmServerWarnings(context, warnings);
  }

  /// Whether this run met the server for the first time just before this
  /// screen; read once, so a sign-in that pins the key does not retitle it.
  late final bool _firstContact = ref
      .read(firstContactServersProvider)
      .contains(identityHandleFor(ref.read(serverUrlProvider)));

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final firstContact = _firstContact;
    final identityStatus = _identityStatus ?? ServerIdentityStatus.unknown;
    final stage = _stage;
    final serverError =
        _errorFor(SignInErrorField.server) ??
        (_creatingAccount ? _probeFailure : null);

    return OnboardingShell(
      // Creating an account is the last of the join steps; signing back in to
      // a server you already trust is one act and gets no stepper.
      step: _creatingAccount ? OnboardingStep.identity : null,
      version: ref.watch(appInfoProvider).valueOrNull?.version,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SignInDestination(
            title: _creatingAccount
                ? 'Create an account'
                : firstContact
                ? 'Sign in'
                : 'Welcome back',
            host: serverHostLabel(_server.text),
            version: _probed,
            // A key saved moments ago by this connect matches nothing from before.
            status:
                firstContact && identityStatus == ServerIdentityStatus.confirmed
                ? ServerIdentityStatus.unknown
                : identityStatus,
            error: _addressExpanded ? null : serverError,
          ),
          const SignInReasonNotices(),
          if (_addressExpanded) ...[
            LabeledField(
              label: 'Server',
              child: AppInput(
                controller: _server,
                placeholder: 'your-server-address.com',
                mono: true,
                errorText: serverError,
                keyboardType: TextInputType.url,
                autocorrect: false,
                semanticLabel: 'Server',
                onChanged: _onServerEdited,
              ),
            ),
            const SizedBox(height: AppSpacing.s8),
          ],
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
          // Each band brings its own gap, so a step not yet open leaves none behind.
          AppRevealBand(
            child: _creatingAccount && invitesOnly(_probed)
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s16),
                    child: InviteCodeField(
                      controller: _invite.controller,
                      accepted: stage == JoinStage.account,
                      busy: _busy,
                      error: _errorFor(SignInErrorField.invite),
                      onChanged: _onInviteEdited,
                      onSubmit: _checkInvite,
                    ),
                  )
                : null,
          ),
          AppRevealBand(
            child: stage == JoinStage.account
                ? Padding(
                    padding: const EdgeInsets.only(top: AppSpacing.s16),
                    child: SignInCredentialFields(
                      username: _username,
                      password: _password,
                      creatingAccount: _creatingAccount,
                      usernameInvalid:
                          _error?.$1 == SignInErrorField.credentials,
                      busy: _busy,
                      errorFor: _errorFor,
                      onSubmit: _submit,
                      onRecoverAccount: () => unawaited(_recoverAccount()),
                    ),
                  )
                : null,
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
            label: switch (stage) {
              JoinStage.account when _creatingAccount => 'Create account',
              JoinStage.account => 'Sign in',
              _ => 'Continue',
            },
            variant: AppButtonVariant.primary,
            size: AppButtonSize.lg,
            full: true,
            busy: _busy,
            onPressed: switch (stage) {
              JoinStage.server => _checkServer,
              JoinStage.invite => _checkInvite,
              JoinStage.account => _submit,
            },
          ),
          const SizedBox(height: AppSpacing.s12),
          // Alternatives to the action above, not a list under it.
          SignInAlternatives(
            creatingAccount: _creatingAccount,
            busy: _busy,
            onToggleCreating: () {
              setState(() {
                _creatingAccount = !_creatingAccount;
                _modeChosen = true;
                _error = null;
              });
              // Creating waits on the server, so a failed answer is worth asking again.
              if (_creatingAccount && _probeFailure != null) {
                unawaited(_checkServer());
              }
            },
            onUseDifferentSpace: () => context.go(Routes.onboarding),
          ),
        ],
      ),
    );
  }
}
