#!/usr/bin/env bash
# Moodle's backup recipe (docker-infrastructure's README, "What an app ships"). The backup runner
# calls it from ~/apps/moodle/ with one argument, an empty folder, and it writes one file there:
#
#   moodle.tar
#     moodle.dump   the whole database, from pg_dump in its custom format, at one moment.
#     moodledata/   the uploaded files and Moodle's other data, taken just after the dump, without
#                   what Moodle rebuilds by itself: cache, localcache, sessions and temp. Restoring
#                   it signs everyone out.
#
# Moodle stays up throughout, without maintenance mode. Its files are named by their content and
# only written before the database refers to them, so a file uploaded during the copy is at worst
# an unused extra. A file deleted after the dump moves to moodledata/trashdir, which is copied last,
# and Moodle takes back a file it is missing from there. The trash is emptied once a day by cron.
# Encrypting, uploading and pruning are the runner's job, not this script's.
#
#   bash backup.sh <empty folder>
set -euo pipefail
# The archive holds the whole site, password hashes included: only its owner may read it.
umask 077

out="${1:?usage: bash backup.sh <empty folder>}"
[ -d "$out" ] || { echo "backup.sh: $out is not a folder" >&2; exit 1; }
# Made absolute before the cd below, so a folder given relative to where it was called still works.
out="$(cd "$out" && pwd)"

# Run from this script's folder, so `docker compose` finds this app's compose file.
cd "$(dirname "$0")"

# Both files are written under temporary names and the archive renamed once complete, so a failure
# never leaves a partial archive where the runner would take it for a backup, even when the runner
# stops this script.
dump="$out/.moodle.dump.partial"
archive="$out/.moodle.tar.partial"
trap 'rm -f "$dump" "$archive"' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# 1. The database, from the running db container. pg_dump reads it all in one transaction, so the
#    dump is consistent however much Moodle changes meanwhile.
docker compose exec -T db sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom' \
  > "$dump" < /dev/null || { echo "backup.sh: the database dump failed" >&2; exit 1; }

# 2. The archive, from a throwaway container of the app's image with moodledata mounted as the app
#    has it and the dump beside it. Its only output on stdout is the archive.
copy_in_container=$(
  cat << 'SH'
set -eu
cd /var
# Every top-level entry of moodledata but what Moodle rebuilds, then trashdir last.
find moodledata -mindepth 1 -maxdepth 1 \
  ! -name cache ! -name localcache ! -name sessions ! -name temp ! -name trashdir > /tmp/members
if [ -e moodledata/trashdir ]; then echo moodledata/trashdir >> /tmp/members; fi
# tar exits 1 when a file changed while it was read, which a running site may do; it still wrote
# the archive. Any other failure exits 2.
tar -cf - -C /backup moodle.dump -C /var --verbatim-files-from -T /tmp/members || [ $? = 1 ]
SH
)
docker compose run --rm --no-deps -T -v "$dump:/backup/moodle.dump:ro" --entrypoint sh app \
  -c "$copy_in_container" > "$archive" < /dev/null \
  || { echo "backup.sh: copying moodledata failed" >&2; exit 1; }

mv "$archive" "$out/moodle.tar"
echo "backup.sh: wrote $out/moodle.tar ($(du -h "$out/moodle.tar" | cut -f1))"
