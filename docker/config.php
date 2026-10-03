<?php
// Moodle's config, built into the image. Settings that differ between the VPS, CI and local development come
// from the container's environment (deploy/docker-compose.yml); everything else is fixed here.

unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'db';
$CFG->dbname    = 'moodle';
$CFG->dbuser    = 'moodle';
$CFG->dbpass    = getenv('POSTGRES_PASSWORD');
$CFG->prefix    = 'mdl_';
$CFG->dboptions = ['dbport' => 5432, 'dbpersist' => false];

// https://training.flyindycenter.com/moodle on the VPS. Moodle redirects any request for another address here.
$CFG->wwwroot  = getenv('MOODLE_WWWROOT');
$CFG->dataroot = '/var/moodledata';
$CFG->admin    = 'admin';
$CFG->directorypermissions = 02777;

// Traefik terminates TLS and talks plain HTTP to this container.
$CFG->sslproxy = str_starts_with($CFG->wwwroot, 'https://');

// docker/apache.conf sends paths that aren't files to r.php, so Moodle's URLs don't need it.
$CFG->routerconfigured = true;

// Plugins and Moodle itself are installed by building a new image, never from the admin pages: the code is
// read-only to the web server.
$CFG->disableupdateautodeploy = true;

require_once(__DIR__ . '/lib/setup.php');
