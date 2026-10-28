// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Typed client for the slim-m wire protocol.
///
/// The contract lives in `schema/openapi.yaml`; this package is its Dart side.
/// Two ideas run through it and are worth knowing before use:
///
/// - Identity and order are separate. A message's `id` is a client-generated
///   UUIDv7 that also makes sending idempotent; its `seq` is the server's
///   per-channel order key and the only correct sync cursor.
/// - Writes go over REST and events arrive over the WebSocket. The socket is a
///   fan-out of things that already happened durably, never the write path.
library;

export 'src/logging/app_log.dart';
export 'src/logging/failure.dart';
export 'src/logging/log_redaction.dart'
    show redactText, redactContext, redactedMark;

// The extensions are named here too because `show` filters by declaration
// name: an extension's methods need its own name exported to be in scope.
export 'src/client.dart'
    show
        SlimmApi,
        Bot,
        ChannelRetention,
        DbPoolStats,
        NewBot,
        NewWebhook,
        RequestClassCount,
        RouteMetric,
        ServerMetrics,
        SpaceRules,
        ChannelUpdate,
        JoinGate,
        Webhook,
        SlimmApiAdmin,
        SlimmApiAdminAudit,
        SlimmApiAttachments,
        SlimmApiUploadSessions,
        kUploadSessionThreshold,
        kUploadPartBytes,
        usesUploadSessions,
        SlimmApiAuth,
        SlimmApiTotp,
        SlimmApiDiagnostics,
        SlimmApiExports,
        SlimmApiDirectRoute,
        SlimmApiLinkedAccounts,
        SlimmApiBotCommands,
        SlimmApiBotUi,
        SlimmApiBots,
        SlimmApiCanvas,
        SlimmApiChannelAdmin,
        SlimmApiDms,
        SlimmApiDock,
        SlimmApiEmoji,
        SlimmApiGifs,
        SlimmApiLinkPreview,
        SlimmApiMemberModeration,
        SlimmApiMessages,
        SlimmApiMetrics,
        SlimmApiModeration,
        SlimmApiModuleCommands,
        SlimmApiModuleSettings,
        SlimmApiModuleSlots,
        SlimmApiModulePermissions,
        SlimmApiNotificationSchedule,
        SlimmApiPresence,
        SlimmApiPush,
        SlimmApiRoles,
        SlimmApiCategoryPermissions,
        ChannelOverwriteSet,
        SlimmApiSpace,
        SlimmApiJoinGate,
        SlimmApiThreads,
        SlimmApiInteractions,
        SlimmApiUsers,
        SlimmApiVoice,
        SlimmApiVoiceCalls,
        SlimmApiVoiceRooms,
        SlimmApiWatchSession,
        SlimmApiWebhooks;
export 'src/session_store.dart' show SessionStore, SessionSync;
export 'src/connection_test.dart';
export 'src/upload_source.dart';
export 'src/events_tallies.dart';
export 'src/events.dart'
    show
        CanvasCleared,
        CanvasCursorMoved,
        CanvasMediaSlotChanged,
        CanvasObjectLockChanged,
        CanvasObjectEdited,
        CanvasObjectMoved,
        CanvasObjectReordered,
        CanvasObjectPlaced,
        CanvasObjectsRemoved,
        CanvasObjectsRestored,
        CanvasStrokePreview,
        CanvasScreenAnnotation,
        CanvasMediaSlotPreview,
        CanvasObjectPreview,
        CanvasView,
        CallRinging,
        CallRingEnded,
        CategoryChanged,
        ChannelCreated,
        ChannelDeleted,
        ChannelUpdated,
        EventConnection,
        EventConnectionRefused,
        ErrorEvent,
        HelloEvent,
        MemberJoined,
        MemberRemoved,
        MemberRestored,
        MemberRoleChanged,
        JoinGateChanged,
        MemberTimeoutChanged,
        MessageCreated,
        MessageDeleted,
        InteractionAnswered,
        InteractionForm,
        MessageComponentsChanged,
        MessageEmbedsChanged,
        MessageLinkPreviewsRemoved,
        MessageEphemeral,
        MessageEdited,
        MessagePinned,
        MessageUnpinned,
        NewDeviceSignIn,
        NotificationOverrideChanged,
        OverwriteChanged,
        PollVoted,
        PongEvent,
        PresenceChanged,
        ProfileChanged,
        BotUiChanged,
        ReactionsChanged,
        ReadStateChanged,
        CodeRunChanged,
        CodeRunsCleared,
        ReportsChanged,
        RoleChanged,
        ServerEvent,
        ThreadUpdated,
        TypingStarted,
        TypingStopped,
        VoiceActivityChanged,
        VoiceMoved,
        VoiceParticipantJoined,
        VoiceParticipantLeft,
        VoiceScreenShareChanged,
        WatchTick,
        protocolVersion;
export 'src/exceptions.dart';
export 'src/limits.dart'
    show
        InputLimits,
        kMessageMaxChars,
        kPasswordMinChars,
        kUserNoteMaxChars,
        usernameCharacters;
export 'src/models.dart';
