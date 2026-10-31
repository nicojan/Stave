#!/bin/bash
# Usage: scripts/ax-dump.sh <process name>
# Prints the role and description of every UI element of the process's front window, through System Events.
# A SwiftUI label on a combined element (a sidebar row) shows up as the text element's value, so the value is printed after the description.
# Needs Accessibility permission for the terminal.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "usage: ax-dump.sh <process name>" >&2
  exit 2
fi
osascript - "$1" <<'APPLESCRIPT'
on run argv
    set processName to item 1 of argv
    tell application "System Events"
        if not (exists process processName) then error "no process named " & processName
        tell process processName
            if (count of windows) is 0 then error "no window for " & processName
            set output to ""
            set elements to entire contents of window 1
            repeat with index from 1 to count of elements
                set element to item index of elements
                set roleText to "?"
                set descriptionText to ""
                set valueText to ""
                try
                    set roleText to (role of element) as text
                end try
                try
                    set found to description of element
                    if found is not missing value then set descriptionText to found as text
                end try
                try
                    set foundValue to value of element
                    if class of foundValue is text then set valueText to foundValue
                end try
                set output to output & roleText & " | " & descriptionText & " | " & valueText & linefeed
            end repeat
            return output
        end tell
    end tell
end run
APPLESCRIPT
