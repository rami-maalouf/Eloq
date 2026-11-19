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
- `packages/matcher`: the one rule for what counts as a word of the library
  (forms, normalizing, scanning a text), shared by the app, the MCP server and
  the typing package.
- `packages/typing`: Eloq in every other Mac app (below).
- `services/mcp`: the MCP server agents use to read and write the library.
- `ops/`: the server on the VPS (the Snapback service, backups, routes).
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

Agents connect through `services/mcp` with `ELOQ_URL=https://eloq.orbitlabs.studio`:
`bun services/mcp/src/main.ts login` once, then an MCP client runs the same file.

## On the Mac, in every app

`packages/typing` puts Eloq where you write. It needs the Accessibility
permission (System Settings, Privacy & Security, Accessibility); the Progress
tab says whether it is on. Text is read to answer one question and is never
stored or sent, and password fields are skipped.

- **The offer.** When the text cursor rests at the end of a word you overuse,
  a small panel shows the words you want to use instead: a word you just typed,
  or one that was already there. Tab takes the first, 1-9 picks one, and any
  other key keeps your word.
- **The underlines.** Amber dots under the words you overuse and a faint green
  line under the targets you used, in the field you write in. They hide while
  you type or scroll. A switch in the Progress tab turns them off.
- **Add a word.** Select text in any app and press Control+Option+Command+L,
  then O (overused) or T (target). The Services menu has the same two commands,
  "Add to Eloq as Overused" and "Add to Eloq as Target".
- **The menu bar item** keeps Eloq running when its window is closed.

It works in native apps and in Electron apps (Slack, Obsidian, T3 Code). A code
editor that draws its own text (VS Code) gives no text to read, so it has no
underlines.

In the app: Cmd+N new word, Cmd+F find, Cmd+1/2/3 the tabs, Cmd+E edit, Cmd+S
save, Esc cancel.

## Tests

```sh
bun test packages/matcher services/mcp   # needs `bun run backend:dev`
bun packages/typing/test/parity.ts       # the Swift lookup against the TypeScript one
cd app && bun exact.mjs test web         # the app, in a browser; needs the backend
sh packages/typing/test/live/run.sh textedit interesting   # the readers on a real native field
sh packages/typing/test/live/run.sh electron chat:interesting   # and on an Electron window
```

The two `live` runs open a window of their own behind your windows, read only
that window, and write a picture to `packages/typing/test/live/out`. The shell
needs the Accessibility and Screen Recording permissions.
