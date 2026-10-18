// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client's local store.
///
/// The store is the single source of truth: the UI observes it, and both
/// delivery routes (live WebSocket push and REST catch-up) write through it.
/// [MessageStore.applyMessage] is where idempotency and ordering are decided, so
/// the two routes can interleave, repeat, or overlap safely.
library;

export 'src/category_store.dart' show CategoryStore;
export 'src/channel_reposition.dart' show ChannelReposition;
export 'src/connection/connection.dart' show openSlimmDatabase;
export 'src/connection/database_key.dart'
    show
        DatabaseEncryptionUnavailable,
        DatabaseInUseElsewhere,
        DatabaseKeyStore,
        DatabaseResetReason,
        DatabaseUnopenable,
        LocalDatabaseKeyUnavailable,
        generateDatabaseKey;
export 'src/database.dart' show SlimmDatabase, Channel, ChannelCategoryRow;
export 'src/message_dto.dart' show ForwardedMessage, Message;
export 'src/message_store.dart'
    show
        MessageStore,
        MessageStoreInbox,
        failInterruptedSends,
        hasMessageFrom,
        interruptedSendReason;
