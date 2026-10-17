# Documentation

Where everything in `docs/` is, and which file to open first.
Tasks and the backlog live on the Planka board, not here; these files hold the reasoning, the runbooks and the reference.

## Start here

1. [DEVELOPING.md](DEVELOPING.md): clone to everything running, and every check CI runs, locally.
2. [ARCHITECTURE.md](ARCHITECTURE.md): a ten minute tour of the code.
3. [BRIEF.md](BRIEF.md): what slim-m is for and what it deliberately is not.
4. [decisions/](decisions/README.md): why things are the way they are; read the record before changing what it decided.
5. [design/design-language.md](design/design-language.md) and [design/desktop-vs-mobile.md](design/desktop-vs-mobile.md) before any UI change.

## Using and running slim-m

- [INSTALL.md](INSTALL.md): installing the app on each platform.
- [OPERATING.md](OPERATING.md): running a server, every setting, two-factor, modules, webhooks, bots, updating.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md): problems by symptom.
- [sizing.md](sizing.md): how big a machine a deployment needs.
- [PRODUCT.md](PRODUCT.md): what the app does today.
- [bots/building-bots.md](bots/building-bots.md), [modules/](modules/README.md) and [webhooks/pointing-tools-at-slim-m.md](webhooks/pointing-tools-at-slim-m.md): extending a deployment.

## Working on the code

- [DEVELOPING.md](DEVELOPING.md): setup, commands and local gates.
- [ci.md](ci.md): every workflow, what it gates and when it runs; [CHANGING-CI.md](CHANGING-CI.md) before editing one.
- [e2e.md](e2e.md): the end-to-end harness (real LiveKit, server and two browsers).
- [RELEASING.md](RELEASING.md): the release runbook; [APP-STORE.md](APP-STORE.md) for the iOS listing and review.
- [dependencies.md](dependencies.md): why each dependency is there.
- [internals.md](internals.md): how and why individual modules work, moved out of long doc comments.
- [video-quality.md](video-quality.md) and [voice-input-gate.md](voice-input-gate.md): how call media is tuned.
- [agents/job-template.md](agents/job-template.md): the job file format for agent work.

## Product direction

- [BRIEF.md](BRIEF.md), [STRATEGY.md](STRATEGY.md) and [ROADMAP.md](ROADMAP.md): the brief, the implementation strategy and the phases.
- [OPEN-QUESTIONS.md](OPEN-QUESTIONS.md): things that need the owner, a device or an account to settle.
- [os_backlog/](os_backlog/README.md): known issues per platform.
- [BETA-TESTERS.md](BETA-TESTERS.md) and [PHONE-TESTER-CHECKLIST.md](PHONE-TESTER-CHECKLIST.md): briefing and checklists for testers.

## Reference and history

- [decisions/](decisions/README.md): architecture and product decision records.
- [design/](design/): the design language, layout rules, wording and earlier explorations.
- [research/](research/README.md): research notes, some superseded; the index says which.
- [reports/](reports/): point-in-time reviews (screen inventories, performance).
- [BACKLOG.md](BACKLOG.md), [IMPLIED-GAPS.md](IMPLIED-GAPS.md) and [phase3-notes.md](phase3-notes.md): historical planning notes from before the Planka board; kept for their reasoning, not as a task list.
