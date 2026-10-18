// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One signed-in server: the identity of an account and where its data lives.
/// See docs/decisions/0068-multiple-servers-in-one-app.md.
library;

/// The database file the pre-accounts install already used, kept by the
/// account that migrates from it so no cache is copied or lost.
const legacyDatabaseFile = 'slimm.sqlite';

/// `scheme://host[:port]`, lowercased: the one key an account is filed under.
String originOf(Uri server) {
  final port = server.hasPort ? ':${server.port}' : '';
  return '${server.scheme}://${server.host}$port'.toLowerCase();
}

/// The key-store handle an account's session is stored under.
String sessionHandleFor(String origin) => 'session:$origin';

/// A stable, filesystem-safe database name for an origin other than the legacy one.
///
/// Two 32-bit hashes rather than one 64-bit: dart2js cannot hold a 64-bit integer exactly.
String databaseFileFor(String origin) {
  var low = 5381;
  var high = 0x811c9dc5;
  for (final unit in origin.codeUnits) {
    low = ((low * 33) ^ unit) & 0xFFFFFFFF;
    high = ((high * 31) ^ unit) & 0xFFFFFFFF;
  }
  final name = '${_hex(high)}${_hex(low)}';
  return 'slimm-$name.sqlite';
}

String _hex(int value) => value.toRadixString(16).padLeft(8, '0');

class Account {
  const Account({
    required this.origin,
    required this.serverUrl,
    required this.dbFile,
  });

  factory Account.forServer(Uri server, {String? dbFile}) {
    final origin = originOf(server);
    return Account(
      origin: origin,
      serverUrl: server,
      dbFile: dbFile ?? databaseFileFor(origin),
    );
  }

  /// Null for an entry that cannot be used, so one bad row never drops the rest.
  static Account? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final url = Uri.tryParse('${json['serverUrl']}');
    final dbFile = json['dbFile'];
    if (url == null || !url.hasScheme || url.host.isEmpty) return null;
    if (dbFile is! String || dbFile.isEmpty) return null;
    return Account(origin: originOf(url), serverUrl: url, dbFile: dbFile);
  }

  final String origin;
  final Uri serverUrl;
  final String dbFile;

  String get sessionHandle => sessionHandleFor(origin);

  Map<String, Object?> toJson() => {
    'origin': origin,
    'serverUrl': serverUrl.toString(),
    'dbFile': dbFile,
  };

  @override
  bool operator ==(Object other) =>
      other is Account && other.origin == origin && other.dbFile == dbFile;

  @override
  int get hashCode => Object.hash(origin, dbFile);
}

/// The persisted list of accounts and which one was in front.
class AccountIndex {
  const AccountIndex({this.accounts = const [], this.activeOrigin});

  final List<Account> accounts;
  final String? activeOrigin;

  Account? get active {
    for (final account in accounts) {
      if (account.origin == activeOrigin) return account;
    }
    return accounts.isEmpty ? null : accounts.first;
  }

  Account? byOrigin(String origin) {
    for (final account in accounts) {
      if (account.origin == origin) return account;
    }
    return null;
  }

  AccountIndex withAccount(Account account) => AccountIndex(
    accounts: [
      for (final a in accounts)
        if (a.origin != account.origin) a,
      account,
    ],
    activeOrigin: activeOrigin,
  );

  AccountIndex without(String origin) => AccountIndex(
    accounts: [
      for (final a in accounts)
        if (a.origin != origin) a,
    ],
    activeOrigin: activeOrigin == origin ? null : activeOrigin,
  );

  AccountIndex withActive(String? origin) =>
      AccountIndex(accounts: accounts, activeOrigin: origin);

  Map<String, Object?> toJson() => {
    'active': activeOrigin,
    'accounts': [for (final a in accounts) a.toJson()],
  };
}
