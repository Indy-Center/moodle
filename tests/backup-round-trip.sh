#!/usr/bin/env bash
# The backup recipe's round trip: give Moodle a course with a file, back it up, restore it over a
# changed site and then onto wiped volumes, and check the course, its file and the admin's sign-in
# come back each time. CI runs it against the stack it has just installed in deploy/; it runs the
# same way locally once `docker compose up -d` has finished there. It throws away the stack's data,
# so never run it on the server.
#
#   bash tests/backup-round-trip.sh
set -euo pipefail

cd "$(dirname "$0")/../deploy"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  docker compose logs --tail 50 >&2 || true
  exit 1
}

# Runs PHP from stdin inside the app container, as the web server's user, with Moodle loaded.
moodle_php() {
  { printf '%s\n' '<?php' "define('CLI_SCRIPT', true);" "require '/var/www/moodle/config.php';"; cat; } \
    | docker compose exec -T app runuser -u www-data -- php
}

# Prints the course with the given short name and the content of its round-trip.txt, one per line.
course() {
  moodle_php << PHP
\$course = \$DB->get_record('course', ['shortname' => '$1']);
if (!\$course) { echo "no course $1\n"; exit; }
echo \$course->fullname, "\n";
\$file = get_file_storage()->get_file(context_course::instance(\$course->id)->id,
  'course', 'overviewfiles', 0, '/', 'round-trip.txt');
try {
  echo \$file ? \$file->get_content() : 'no file', "\n";
} catch (Exception \$e) {
  echo "file content missing\n";
}
PHP
}

# Makes a course with the given short name and full name, with a file round-trip.txt holding $3.
add_course() {
  moodle_php << PHP > /dev/null
require_once(\$CFG->dirroot . '/course/lib.php');
\$course = create_course((object) ['shortname' => '$1', 'fullname' => '$2',
  'category' => core_course_category::get_default()->id]);
get_file_storage()->create_file_from_string(['contextid' => context_course::instance(\$course->id)->id,
  'component' => 'course', 'filearea' => 'overviewfiles', 'itemid' => 0, 'filepath' => '/',
  'filename' => 'round-trip.txt'], '$3');
PHP
}

# Signs in as admin with the password the stack was installed with, and checks the dashboard answers.
admin_signs_in() {
  docker compose exec -T app sh -c '
    cd "$(mktemp -d)"
    token=$(curl -fsS -c jar http://localhost/login/index.php | grep -o "name=\"logintoken\" value=\"[^\"]*" | cut -d\" -f4)
    curl -fsS -b jar -c jar -o /dev/null --data-urlencode username=admin \
      --data-urlencode "password=$MOODLE_ADMIN_PASSWORD" --data-urlencode "logintoken=$token" \
      http://localhost/login/index.php
    test "$(curl -s -b jar -o /dev/null -w "%{http_code}" http://localhost/my/)" = 200
  ' < /dev/null
}

# Checks the backed-up course and its file are there, the later one isn't, and the admin signs in.
check_restored() {
  [ "$(course RT101)" = "$(printf '%s\n' 'Round trip course' 'Made by the round trip.')" ] \
    || fail "$1: the course or its file didn't come back: $(course RT101)"
  [ "$(course LATER)" = "no course LATER" ] || fail "$1: the course made after the backup is still there"
  admin_signs_in || fail "$1: the admin can't sign in"
  [ -n "$(docker compose ps -q --status running cron)" ] || fail "$1: cron isn't running"
}

echo "--- Known content: a course with a file, and something in each folder the backup leaves out"
[ "$(course RT101)" = "no course RT101" ] \
  || fail "the stack already has the round trip's course; run this on a freshly installed stack"
add_course RT101 'Round trip course' 'Made by the round trip.'
[ "$(course RT101)" = "$(printf '%s\n' 'Round trip course' 'Made by the round trip.')" ] \
  || fail "could not make the course: $(course RT101)"
docker compose exec -T app sh -c 'for d in cache localcache sessions temp; do
  mkdir -p /var/moodledata/$d && touch /var/moodledata/$d/round-trip-marker; done' < /dev/null

echo "--- Back up"
mkdir "$work/out"
# Called from elsewhere with a relative folder, as a person might.
(cd "$work" && bash "$OLDPWD/backup.sh" out) || fail "backup.sh exited $?"
files="$(ls -A "$work/out")"
[ "$files" = moodle.tar ] || fail "backup.sh should write moodle.tar alone, but wrote: ${files:-nothing}"
backup="$work/out/moodle.tar"
[ -O "$backup" ] || fail "the backup is not owned by the user who ran backup.sh"
[ "$(stat -c %a "$backup")" = 600 ] || fail "the backup's mode is $(stat -c %a "$backup"), not 600"

# The database dump, the uploaded files, and none of what Moodle rebuilds.
tar -tf "$backup" > "$work/members"
grep -qx moodle.dump "$work/members" || fail "moodle.tar holds no moodle.dump"
grep -q '^moodledata/filedir/' "$work/members" || fail "moodle.tar holds no moodledata/filedir"
left_in="$(grep -E '^moodledata/(cache|localcache|sessions|temp)(/|$)' "$work/members" || true)"
[ -z "$left_in" ] || fail "moodle.tar holds what Moodle rebuilds: $left_in"

echo "--- Change the site after the backup: another course, and a stray file in moodledata"
add_course LATER 'Made after the backup' 'Should not survive the restore.'
docker compose exec -T app touch /var/moodledata/round-trip-stray < /dev/null

echo "--- Restore over the running site"
bash restore.sh "$backup" || fail "restore.sh exited $?"
check_restored "after restoring over the site"
[ -z "$(docker compose exec -T app sh -c 'ls /var/moodledata/round-trip-stray 2>/dev/null || true' < /dev/null)" ] \
  || fail "restore.sh left a file in moodledata that the backup didn't have"

echo "--- Wipe the stack and its volumes, as on a rebuilt server"
docker compose down --volumes

echo "--- Restore onto nothing"
bash restore.sh "$backup" || fail "restore.sh exited $?"
check_restored "after restoring onto wiped volumes"
docker compose logs app | grep -q 'Installing Moodle' \
  && fail "the app installed a new Moodle instead of starting on the restored database"

echo "PASS: backup and restore round trip"
