# Eloq

Eloq helps you trade the words you overuse for the words you want to use: a
library of overused and target words, the links between them ("move from X to
Y"), and what you actually say and write over time.

This is the rewrite on [Exact](https://github.com/expo/exact) with
[Snapback](https://github.com/expo/snapback) sync. It works fully offline: every
read and write goes to the store on the device, and a Snapback server syncs your
devices and keeps a backup. The previous SwiftUI app is at the tag `swift-v1`
and the branch `swift`.

## Layout

- `snapback/schema.q`: the synced data (tables, rules, queries, mutations).
- `app/`: the Exact app (Contract view, TypeScript data logic, and the Rust
  workspace that links the Snapback device on Apple platforms).
- `scripts/sync-snapback-adapter.sh`: copies the Snapback adapter for Exact into
  the Exact checkout the app builds against.

## Run it

```sh
bun install                       # snapback4 (the server CLI) for the backend
bun run backend:dev               # a local snapback server on 127.0.0.1:4420
cd app && bun exact.mjs mac --run # the macOS app
```

The app expects an Exact checkout at `../../expo-exact-eloq` with the Snapback
adapter in it (`scripts/sync-snapback-adapter.sh`).

`app.ts` names the local development server, so tests run against it. A build for
daily use bakes the real server instead:

```sh
cd app && EXACT_BACKEND_ORIGIN=https://eloq.orbitlabs.studio bun exact.mjs mac --run
```

Agents connect through `services/mcp` with `ELOQ_URL=https://eloq.orbitlabs.studio`.

Status: early. The app is still the sync starter; the vocabulary app is being
built on top of it.
