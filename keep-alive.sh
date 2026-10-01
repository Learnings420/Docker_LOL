#!/usr/bin/env bash
# Light activity generator. NOTE: not a guaranteed way to stop Codespace idle timeout.
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" || exit 1
LOG_FILE="keep_alive.log"
INTERVAL="${INTERVAL:-240}"   # seconds (must be well below the idle timeout)

while true; do
  echo "Keep-alive activity generated at $(date)" >> "$LOG_FILE"
  tail -n 200 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"   # keep log small
  sleep "$INTERVAL"
done
