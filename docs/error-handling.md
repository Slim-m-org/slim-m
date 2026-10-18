# Error handling and the debug log

Every failure the client catches is logged once, in one place, and the user sees it through the persistent `AppErrorState`, never a SnackBar.

## The logger

`AppLog` lives in the `api` package (`client/packages/api/lib/src/logging/`), the lowest layer every other package already depends on.
`rtc`, `platform` and `data` call it directly; the app installs one sink, `DebugLog`, at startup.
Records logged before the sink exists are buffered and replayed.

- Levels are `debug`, `info`, `warning`, `error`.
- Tags come from `LogTag`: `sync`, `push`, `voice`, `auth`, `media`, `data`, `platform`, `ui`, `net`.
- Everything is redacted before any sink sees it: bearer tokens, JWTs, `password=` style pairs, long opaque tokens, and context keys such as `token`, `password`, `content` and `body`.
- Never put message content in the message or the context; log ids and counts.
- The app keeps the newest 200 records, folds identical consecutive ones into one counted entry, drops debug records first when full, and persists the ring to preferences so a crash can still be reported.

## Which call to use

- A real failure: `reportFailure(tag, 'do the thing', error, stack)`.
  It classifies the failure (`offline`, `authExpired`, `refused`, `unexpected`), logs it once at warning or error, and returns the classification.
- A failure shown to the user: `reportFailureSentence(...)` in `api_failure.dart`, or `runGuarded` / `GuardedActionState.guard`, which call it.
  Render the returned sentence with `AppErrorState` or an inline caption.
- A swallow that is intended (best-effort cleanup, an optional plugin): `AppLog.swallowed(tag, 'why this is safe', error, stack)`, which logs at debug.
- A `catchError` that ignores: `ignoreError(tag, 'why')`.

## Writing the message

Say what happened in plain words someone can act on, such as "Could not read the saved session; staying signed out".
Never point at code ("see the class doc"), never repeat the tag, and never leave a generated name such as "set state failed".
Real failures are errors, expected degradations are warnings or info, and only noise is debug.
`reportFailure` prefixes "Could not", so pass a verb phrase like `save the profile`.
`client/packages/api/test/log_message_quality_test.dart` fails on the first two and on generated names.

## What the gate enforces

`client/packages/api/test/no_silent_catch_test.dart` fails on a catch clause or `catchError` handler with an empty body, and on `debugPrint` outside the logger.
A deliberate swallow still has a body, and the reason string is the comment.

## The debug log screen

Settings, Troubleshooting, Debug log.
It filters by level, area and a search term, one line per entry that opens in place, and Copy exports what is shown, redacted again at export time.
