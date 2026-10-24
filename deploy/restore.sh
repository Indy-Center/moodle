#!/usr/bin/env bash
# Puts a backup made by backup.sh back into Moodle (docker-infrastructure's README, "What an app
# ships"). Run it as deploy from ~/apps/moodle/, with the decrypted moodle.tar the runner's helpers
# fetched:
#
#   bash restore.sh <path to moodle.tar>
#
# It replaces the whole database and moodledata with the backup's: anything changed since that
# backup is lost, and everyone is signed out. Moodle and its cron are stopped while it runs. It
# works on a running site and on a rebuilt server with no containers or volumes yet.

# The single-quoted commands below are expanded inside the containers, not here.
# shellcheck disable=SC2016
set -euo pipefail

backup="${1:?usage: bash restore.sh <path to moodle.tar>}"
[ -f "$backup" ] || { echo "restore.sh: no such file: $backup" >&2; exit 1; }
dir="$(cd "$(dirname "$backup")" && pwd)"
name="$(basename "$backup")"
backup="$dir/$name"

# Run from this script's folder, so `docker compose` finds this app's compose file.
cd "$(dirname "$0")"

say() { echo "restore.sh: $*"; }

# Where the dump is unpacked inside the db container. Commands run there by in_db get it as
# $RESTORE_DIR. It is removed however this script ends.
work=/tmp/restore
in_db() { docker compose exec -T -e RESTORE_DIR="$work" db "$@"; }

# Set while Moodle is stopped and its data half replaced, for the message a failure leaves.
replacing=
on_exit() {
  local status=$?
  if [ "$status" != 0 ] && [ -n "$replacing" ]; then
    say "the restore failed, so Moodle and its cron are left stopped. Fix the cause and run restore.sh" >&2
    say "again; a deploy would start Moodle on whatever the failed restore left." >&2
  fi
  in_db rm -rf "$work" < /dev/null > /dev/null 2>&1 || true
}
trap on_exit EXIT

# 1. Make sure the database is running (after a rebuild it may not be yet), then check the backup
#    holds a Moodle database and moodledata, all before Moodle is touched. A bad file stops here
#    with Moodle still up.
say "starting the database if it isn't running"
docker compose up -d --wait db
say "checking $backup"
unreadable() { say "$backup isn't a readable backup from backup.sh; nothing was changed" >&2; exit 1; }
in_db sh -c 'rm -rf "$RESTORE_DIR" && mkdir "$RESTORE_DIR" && tar -x -C "$RESTORE_DIR" moodle.dump' \
  < "$backup" || unreadable
# grep reads all its input (no -q), so what it reads from never fails on a closed pipe.
in_db pg_restore --list "$work/moodle.dump" < /dev/null | grep ' TABLE public mdl_config ' > /dev/null \
  || unreadable
in_db tar -t < "$backup" | grep '^moodledata/filedir/' > /dev/null || unreadable

# 2. Stop Moodle and its cron, so nothing writes to the database or moodledata while they are
#    replaced. If a later step fails they are left stopped: started on a half-restored site, Moodle
#    would install itself afresh into an empty database.
say "stopping Moodle and its cron"
replacing=yes
docker compose stop app cron

# 3. Replace the database: drop it (closing any connections left), create it empty, and load the
#    dump into it in one transaction. This runs against the "postgres" database, since the one
#    being replaced can't be dropped while connected to it.
say "replacing the database"
in_db sh -c '
  set -eu
  dropdb -U "$POSTGRES_USER" --maintenance-db=postgres --force --if-exists "$POSTGRES_DB"
  createdb -U "$POSTGRES_USER" --maintenance-db=postgres --owner="$POSTGRES_USER" "$POSTGRES_DB"
  pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner --single-transaction --exit-on-error \
    "$RESTORE_DIR/moodle.dump"
' < /dev/null

# 4. Replace moodledata, in a throwaway container of the app's image with the volume mounted as the
#    app has it: empty it, unpack the backup's moodledata/ into it, and give it to the web server's
#    user. Moodle makes cache, localcache, sessions and temp again as it needs them. The container
#    carries app's labels, so traefik.enable=false keeps Traefik from sending visitors to it.
say "replacing moodledata"
docker compose run --rm --no-deps -T -l traefik.enable=false -v "$dir:/backup:ro" -e NAME="$name" \
  --entrypoint sh app -c '
  set -eu
  find /var/moodledata -mindepth 1 -delete
  tar -x -f "/backup/$NAME" -C /var moodledata
  chown -R www-data:www-data /var/moodledata
' < /dev/null

# 5. Start Moodle and its cron. up returns once Moodle answers; its entrypoint first upgrades the
#    database if the backup is from an older Moodle. Then empty Moodle's caches, so nothing cached
#    before the restore is served after it.
replacing=
say "starting Moodle and its cron"
# up, not start: after a rebuild there are no containers yet to start.
docker compose up -d --wait app cron \
  || { say "the data was restored, but Moodle didn't start on it: see docker compose logs app" >&2; exit 1; }
say "purging Moodle's caches"
docker compose exec -T app runuser -u www-data -- php /var/www/moodle/admin/cli/purge_caches.php < /dev/null \
  || { say "Moodle is back up on the restored data, but purging its caches failed: run admin/cli/purge_caches.php" >&2; exit 1; }
say "done: Moodle is back up on the restored database and moodledata"
