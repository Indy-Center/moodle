#!/bin/sh
# Healthy once Moodle serves its login page, which needs its database. Moodle redirects requests for any
# address but its wwwroot, so the request carries wwwroot's hostname and path.
set -eu
host=$(printf '%s' "$MOODLE_WWWROOT" | cut -d/ -f3)
path=$(printf '%s' "$MOODLE_WWWROOT" | cut -d/ -f4-)
curl -fsS -o /dev/null -H "Host: $host" "http://127.0.0.1/$path/login/index.php"
