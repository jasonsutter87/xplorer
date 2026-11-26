#!/bin/zsh
# Make Xplorer the default folder viewer (or `--undo` to give it back to Finder).
set -e
BID=local.xplorer
HELPER=$(dirname "$0")/../build/set_handler
swiftc -O "$(dirname "$0")/set_handler.swift" -o "$HELPER" 2>/dev/null
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [[ "$1" == "--undo" ]]; then
  defaults delete -g NSFileViewer 2>/dev/null || true
  "$HELPER" com.apple.finder
  echo "Finder is the default again."
else
  $LSREG -f ~/Applications/Xplorer.app
  defaults write -g NSFileViewer -string $BID      # "Show in Finder" / reveal from other apps
  "$HELPER" $BID
  echo "Xplorer is now the default folder viewer. Undo: $0 --undo"
fi
