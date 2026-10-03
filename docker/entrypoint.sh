#!/bin/sh
# Starts Moodle's web server (the default command), or its cron loop when the command is "cron".
# Before the web server starts, it installs Moodle into an empty database, or upgrades the database after the
# image's Moodle version changed. Only the app service does that; cron waits for app to be healthy first.
set -eu
cd /var/www/moodle

# Moodle's CLI scripts run as the web server's user, so the files they write in moodledata stay writable.
as_www() {
  runuser -u www-data -- "$@"
}

# Prints "installed" or "empty", or fails while the database isn't accepting connections yet.
db_state() {
  php -r '
    $db = @pg_connect("host=db dbname=moodle user=moodle password=" . getenv("POSTGRES_PASSWORD"));
    if (!$db) { exit(1); }
    $row = pg_fetch_row(pg_query($db, "SELECT to_regclass(\x27mdl_config\x27) IS NOT NULL"));
    echo $row[0] === "t" ? "installed" : "empty";
  '
}

until state=$(db_state); do
  echo "Waiting for the database..."
  sleep 2
done

# A new volume starts out owned by root.
chown www-data:www-data /var/moodledata

if [ "${1:-}" = cron ]; then
  # Moodle wants its cron run every minute. Without --keep-alive=0, cron.php stays running for three minutes
  # and logs every second it spends waiting for new tasks.
  while true; do
    as_www php admin/cli/cron.php --keep-alive=0 || echo "cron.php exited with $?"
    sleep 60
  done
fi

if [ "$state" = empty ]; then
  echo "Installing Moodle into the empty database..."
  as_www php admin/cli/install_database.php --agree-license --lang=en \
    --adminuser=admin --adminpass="$MOODLE_ADMIN_PASSWORD" --adminemail="$MOODLE_ADMIN_EMAIL" \
    --fullname="Indy Center Training" --shortname="ZID Training"
else
  as_www php admin/cli/upgrade.php --non-interactive
fi

exec "$@"
