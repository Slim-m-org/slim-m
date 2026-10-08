// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The value types a voice call exposes to the rest of the client.
///
/// Split out of `voice_session.dart` when that file reached the 500-line
/// ceiling. Deliberately plain values with no LiveKit types in them, for the
/// reason the session's own doc comment gives: the UI needs names and
/// booleans, not a live SDK object it could subscribe to behind our back.
library;

/// Where a session is in its lifecycle.
enum VoiceSessionState {
  /// Not in a call.
  idle,

  /// Token in hand, negotiating with the SFU.
  connecting,

  /// In the call.
  connected,

  /// The last attempt failed, or the connection dropped and did not recover.
  /// `VoiceSession.lastError` says what happened.
  failed,
}

/// Why a call ended, when it was not this client that ended it.
///
/// The SFU reports a reason on every disconnect and nothing read it, so a call
/// that was dropped looked exactly like a call that was left.
enum VoiceDisconnect {
  /// The same account joined from somewhere else and took this slot. The SFU
  /// allows one connection per identity and evicts the older one.
  replacedByOtherDevice,

  /// A moderator removed this participant, or the room went away. LiveKit
  /// reports the same reason for the server's own liveness sweep, but the
  /// app layer reclassifies that case as [heartbeatLagEviction] before it
  /// ever reaches here (see `voice_controller.dart`), using its own record of
  /// whether this client's heartbeat had recently succeeded. This value is
  /// left covering only the causes that record could not explain, so the
  /// message below no longer has to hedge across all three.
  removed,

  /// The SFU reported [removed], but this client's own heartbeat had been
  /// failing to reach the server when it happened - almost certainly the
  /// server's stale-heartbeat sweep evicting a connection that was never
  /// really gone, rather than a moderator's decision. Treated as retryable
  /// the same way [connectionLost] is.
  heartbeatLagEviction,

  /// The connection dropped and reconnecting did not recover it.
  connectionLost,

  /// Ended for a reason this client cannot name.
  unknown;

  /// What to tell the user, in their terms rather than the SFU's.
  String get message => switch (this) {
        replacedByOtherDevice =>
          'You joined this call from another device, so this one left it.',
        removed => "You're no longer in this call.",
        heartbeatLagEviction =>
          'The call dropped for a moment. Reconnecting...',
        connectionLost => 'The call disconnected and could not reconnect.',
        unknown => 'The call ended unexpectedly.',
      };
}

/// Somebody in the call, including you.
///
/// Deliberately a plain value rather than a LiveKit participant: the UI needs
/// an identity, a name, and three booleans, and handing it a live SDK object
/// would let a widget subscribe to something this class is supposed to own.
class VoiceParticipant {
  const VoiceParticipant({
    required this.identity,
    required this.name,
    required this.isSpeaking,
    required this.isMuted,
    required this.isLocal,
    required this.isScreenSharing,
    this.isCameraOn = false,
    this.audioLevel = 0,
  });

  /// The server's user id. The token's `sub`, so it is trustworthy.
  final String identity;

  /// Display name as the token carried it.
  final String name;

  final bool isSpeaking;
  final bool isMuted;
  final bool isLocal;
  final bool isScreenSharing;

  /// Whether this participant has a camera track published. Watched live
  /// through `VoiceSession.cameraViewFor`, the same way [isScreenSharing] is
  /// watched through `screenShareViewFor`.
  final bool isCameraOn;

  /// The last level LiveKit reported for this participant's mic, 0 to 1,
  /// refreshed with its active-speaker updates rather than per audio frame.
  final double audioLevel;

  @override
  bool operator ==(Object other) =>
      other is VoiceParticipant &&
      other.identity == identity &&
      other.name == name &&
      other.isSpeaking == isSpeaking &&
      other.isMuted == isMuted &&
      other.isLocal == isLocal &&
      other.isScreenSharing == isScreenSharing &&
      other.isCameraOn == isCameraOn &&
      other.audioLevel == audioLevel;

  @override
  int get hashCode => Object.hash(
        identity,
        name,
        isSpeaking,
        isMuted,
        isLocal,
        isScreenSharing,
        isCameraOn,
        audioLevel,
      );
}

/// A camera this desktop offers, for the picker several webcams makes
/// necessary. Mobile never lists these: the OS owns which camera answers
/// "the camera", and flipping it is [VoiceSession.flipCamera]'s job.
class CameraDevice {
  const CameraDevice({required this.id, required this.label, this.groupId});

  /// Opaque to us, and the only thing a device switch matches on.
  final String id;

  /// The platform's own device label.
  final String label;

  /// The platform's own grouping of devices that share one piece of
  /// hardware, when it reports one at all; see `dedupeCameraDevices`. Null
  /// on a platform that never populates it for cameras, this app's own
  /// desktop backend included.
  final String? groupId;
}

/// A microphone or speaker this device offers, for the pickers in Voice
/// settings. [CameraDevice]'s own shape: nothing outside this package
/// should hold a `lk.MediaDevice`, audio included.
class AudioDevice {
  const AudioDevice({required this.id, required this.label, this.groupId});

  /// Opaque to us, and the only thing a device switch matches on.
  final String id;

  /// The platform's own device label. Can arrive blank on web before
  /// microphone permission is granted; the picker is responsible for a
  /// readable fallback, not this value.
  final String label;

  /// The platform's own grouping of devices that share one piece of
  /// hardware, when it reports one at all.
  final String? groupId;
}
