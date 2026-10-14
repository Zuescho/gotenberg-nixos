#!/usr/bin/env bash
# Probe Gotenberg /health. Exit status is curl's status.
#   scripts/check-health.sh
#   scripts/check-health.sh http://gotenberg.dueren.de/health
#   scripts/check-health.sh https://gotenberg.dueren.de/health
set -euo pipefail
url="${1:-http://127.0.0.1:3000/health}"
curl --fail --silent --show-error --max-time 10 "$url"
echo
