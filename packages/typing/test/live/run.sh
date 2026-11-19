#!/bin/sh
# the live proof of @eloq/typing: its readers and windows on real text fields, with no screen
# capture (only the fixture's window and eloq's own are captured, by id). textedit and electron
# use no key tap and stay behind your windows.
#
#   sh run.sh textedit [<word>]              a native field (a text file of its own in textedit)
#   sh run.sh electron [<field>:<word>[:n]]  the fields of an electron app (./electron)
#   sh run.sh e2e                            the offer end to end, through the running eloq app:
#                                            the fixture takes the front and the keyboard for 15 s
#
# the shell needs the accessibility and screen recording permissions. pictures go to ./out.
# the fixture opens behind the other windows and is closed at the end. textedit also reopens
# any documents it had open before; they are left alone.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
apple="$here/../../apple"
out="$here/out"
mkdir -p "$out"
swiftc -O "$apple/TypingLookup.swift" "$apple/AX.swift" "$apple/Layout.swift" "$apple/Caret.swift" "$apple/Underlines.swift" \
  "$apple/Panels.swift" "$apple/Capture.swift" "$apple/Gate.swift" "$apple/Watcher.swift" "$here/harness/main.swift" -o "$out/harness"

case "${1:-}" in
textedit)
  file="$out/eloq-typing-live.txt"
  { echo "This is a very interesting demo, and it is really nice to see a bunch of words."
    echo "A compelling story is vivid and precise. Basically, it was kind of interesting."
    echo
    echo "The long line below wraps inside the window so that a phrase such as a bunch of words can break across two lines when the window is narrow, which is really the case to test here: kind of tricky, very tricky."
    i=1; while [ $i -lt 80 ]; do echo "Filler line $i has a very plain sentence and one compelling word."; i=$((i + 1)); done; } > "$file"
  was_running=$(pgrep -x TextEdit || true)
  open -g -a TextEdit "$file"
  sleep 3
  "$out/harness" "$out/textedit.png" "$(pgrep -x TextEdit | head -1)" "eloq-typing-live" ${2:+"$2"} || true
  osascript -e 'tell application "System Events" to tell process "TextEdit" to click (first button of (first window whose name contains "eloq-typing-live") whose subrole is "AXCloseButton")' >/dev/null 2>&1 || true
  [ -n "$was_running" ] || pkill -x TextEdit || true
  ;;
electron)
  cd "$here/electron"
  [ -d node_modules/electron ] || bun install
  # an electron app that starts this script (an editor, a terminal in one) sets this, and electron then runs as node
  env -u ELECTRON_RUN_AS_NODE node_modules/electron/dist/Electron.app/Contents/MacOS/Electron . "${2:-}" >/dev/null 2>&1 &
  fixture=$!
  sleep 4
  "$out/harness" "$out/electron.png" "$fixture" "eloq-typing-live" || true
  kill "$fixture" 2>/dev/null || true
  ;;
e2e)
  # the offer end to end: real keys through the running app's tap into the fixture, in front
  swiftc -O "$apple/TypingLookup.swift" "$apple/AX.swift" "$apple/Layout.swift" "$apple/Caret.swift" "$apple/Underlines.swift" \
    "$here/e2e/main.swift" -o "$out/e2e"
  cd "$here/electron"
  [ -d node_modules/electron ] || bun install
  before=$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)
  env -u ELECTRON_RUN_AS_NODE node_modules/electron/dist/Electron.app/Contents/MacOS/Electron . "scratch:" front >/dev/null 2>&1 &
  fixture=$!
  sleep 4
  status=0
  "$out/e2e" "$fixture" || status=$?
  kill "$fixture" 2>/dev/null || true
  [ -z "$before" ] || open -b "$before" 2>/dev/null || true
  exit "$status"
  ;;
*)
  sed -n '2,13p' "$0"
  exit 64
  ;;
esac
