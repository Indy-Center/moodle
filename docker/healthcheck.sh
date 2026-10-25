#!/bin/sh
# Healthy once Moodle serves its login page, which needs its database. Moodle redirects requests for any
# address but its wwwroot, so the request carries wwwroot's hostname.
set -eu
host=$(printf '%s' "$MOODLE_WWWROOT" | cut -d/ -f3)
curl -fsS -o /dev/null -H "Host: $host" http://127.0.0.1/login/index.php
