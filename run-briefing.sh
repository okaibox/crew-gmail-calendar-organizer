#!/bin/bash
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/Users/okai/.local/bin:/Users/okai/.bun/bin:/usr/bin:/bin:/usr/local/bin"
export HOME="/Users/okai"

OUTPUT=$(bash "$SCRIPTS/daily-briefing.sh" 2>&1)
bash "$SCRIPTS/notify-telegram.sh" "$OUTPUT"
echo "$OUTPUT" >> "$SCRIPTS/cron.log"
