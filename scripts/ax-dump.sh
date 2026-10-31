#!/bin/bash
# Usage: scripts/ax-dump.sh <process name>
# Prints role | description | value for every UI element of the process's front window (the front window is the first in its
# accessibility window list). Reads the accessibility tree directly (scripts/ax-dump.swift) because System Events returns the role
# description instead of the label for many SwiftUI controls. Needs Accessibility permission for the terminal.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "usage: ax-dump.sh <process name>" >&2
  exit 2
fi
exec swift "$(dirname "$0")/ax-dump.swift" "$1"
