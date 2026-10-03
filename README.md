# moodle

[Moodle](https://moodle.org), Indy Center's learning management system, run in Docker on the Vanderbilt VPS at <https://training.flyindycenter.com/moodle>. Students and instructors use its web pages; nothing else calls it yet.

[![Build and Deploy](https://github.com/Indy-Center/moodle/actions/workflows/build-and-deploy.yml/badge.svg)](https://github.com/Indy-Center/moodle/actions/workflows/build-and-deploy.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Not deployed yet: the repository has no `ENV_*` secrets and no access to the `VANDERBILT_*` deploy credentials, so every deploy stops before it reaches the VPS. `/moodle` also isn't routed to the VPS yet (see [Routing](#routing)). People sign in with Moodle's own accounts, not with identity.

## HTTP surface

Everything is under `/moodle`; Traefik sends nothing else here.

- `GET /moodle/` — the site home page.
- `GET /moodle/login/index.php` — sign in. The deploy and the container's healthcheck request it.
- `GET /moodle/admin/` — site administration, for the admin account.
- `/moodle/pluginfile.php/...` — uploaded course files, checked against the signed-in user's access.
- `/moodle/webservice/...` — Moodle's web service APIs, off until someone enables them in site administration.
- Any other path that isn't a file goes to Moodle's router, `r.php`, for its newer routes such as `/moodle/api/rest/v2/...`.

## Project layout

- `Dockerfile`: builds the image the VPS runs: PHP 8.3 with Apache, the PHP extensions Moodle needs, Moodle's release tarball checked against its published SHA-256, and the files in `docker/`.
- `docker/config.php`: Moodle's `config.php`. Reads the address, database password and admin details from the environment.
- `docker/apache.conf`: serves Moodle's `public/` directory at `/moodle`, sends other paths to the router, and caps Apache at 12 PHP workers.
- `docker/php.ini`: the PHP settings Moodle asks for, plus OPcache.
- `docker/entrypoint.sh`: waits for the database, installs Moodle into an empty one or upgrades an existing one, then starts Apache. With the `cron` command it runs Moodle's cron every minute instead.
- `docker/healthcheck.sh`: requests the login page with the hostname Moodle expects.
- `deploy/`: everything deployed to `/home/deploy/apps/moodle/` on the VPS, and nothing else.
  - `docker-compose.yml`: Moodle (`app`), its cron (`cron`), its Postgres database (`db`), their volumes and the Traefik labels.
  - `.env.example`: the runtime settings the deploy writes to `.env`.
- `.github/workflows/ci.yml`: builds the image, starts the stack on the runner, then checks Moodle installs, the admin can sign in, a restart doesn't reinstall, and cron runs.
- `.github/workflows/build-and-deploy.yml`: runs CI, pushes the image to `ghcr.io/indy-center/moodle`, then rsyncs `deploy/` to the VPS and runs `docker compose up -d` over SSH.

## Routing

`training.flyindycenter.com` belongs to training-app's Worker as a custom domain, so today every path on it, `/moodle` included, goes to the Worker. To send `/moodle` to the VPS, as [Sharing hostnames with Workers](https://tech.flyindycenter.com/patterns/vps-apps/) describes:

1. In training-app's `wrangler.jsonc`, change the custom domain to a route: `{ "pattern": "training.flyindycenter.com/*", "zone_name": "flyindycenter.com" }`. The Worker still serves the same hostname, so identity's cookie keeps working.
2. Because a route doesn't create a DNS record the way a custom domain does, add a proxied `A` record for `training` pointing at the VPS in Cloudflare.
3. In Cloudflare's dashboard, add a route `training.flyindycenter.com/moodle*` with no Worker. It's more specific than the Worker's, so those requests go to the VPS.

Steps 2 and 3 live in the Cloudflare dashboard, not in any repository; note them in training-app's README too. Until all three are done, Moodle can run on the VPS but nobody can reach it, and the deploy's last check fails.

Because the record is proxied, Cloudflare caps a single upload at 100 MB, so `docker/php.ini` uses the same limit. Course backups bigger than that have to be restored from the VPS with `admin/cli/restore_backup.php`.

## Data

Two Docker volumes on the VPS, named after the repository: `moodle_db-data` (the Postgres database) and `moodle_moodledata` (uploaded files, caches, sessions). Backups are handled by a separate service. Renaming the repository starts Moodle on new, empty volumes.

## Accounts

The first deploy installs Moodle with one account, `admin`, whose password and email come from `ENV_MOODLE_ADMIN_PASSWORD` and `ENV_MOODLE_ADMIN_EMAIL`. Those are only read at install; change them in Moodle afterwards. Self-registration is off by default, so the admin creates everyone else's account.

Moodle can't send email yet: no SMTP server is configured. Password resets and notifications won't arrive until one is set in **Site administration → Server → Email → Outgoing mail configuration**.

Signing in with identity is possible later through Moodle's OAuth 2 plugin, once identity's `/oauth/*` endpoints are deployed (DEV-136).

## Plugins and upgrades

Moodle's code is baked into the image and read-only to the web server, so plugins and upgrades can't be installed from the admin pages. To upgrade Moodle, change `MOODLE_VERSION`, `MOODLE_BRANCH` and `MOODLE_SHA256` in the `Dockerfile` in a pull request. The deploy's entrypoint runs Moodle's database upgrade before Apache starts. Moodle can't downgrade, so take a backup first. To add a plugin, add a step to the `Dockerfile` that downloads it into the right directory under `public/`.

Moodle 5.3, the next long-term support release, is due in October 2026. Upgrading to it once it's out is the same three-line change.

## Local development

Needs Docker.

```bash
docker network create traefik-shared   # once; stands in for the VPS's Traefik network
docker build -t ghcr.io/indy-center/moodle:latest .
cd deploy
POSTGRES_PASSWORD=moodle MOODLE_ADMIN_PASSWORD='Local-Pass1!' MOODLE_ADMIN_EMAIL=you@example.com \
  MOODLE_WWWROOT=http://localhost/moodle docker compose up -d
```

`up -d` returns once Moodle is installed, about two minutes on an empty database. Traefik isn't running locally, so either add `ports: ['80:80']` to `app` and open <http://localhost/moodle>, or use `docker compose exec app curl ...`. `docker compose down -v` throws Moodle and its data away.

## Deployment

`build-and-deploy.yml` runs on every push to `main`, and by hand from **Actions → Build and Deploy → Run workflow**. It calls `ci.yml` first and only deploys if it passes, checks the containers are still up 15 seconds later, then requests the login page through Cloudflare and Traefik. [Deploying to the VPS](https://tech.flyindycenter.com/patterns/vps-apps/) describes the pipeline.

Before the first deploy:

1. An org admin adds this repository to the organization's `VANDERBILT_*` variables and secrets (all four).
2. Set the repository's `ENV_*` secrets and variables; `deploy/.env.example` describes each one. Keep the source copies in 1Password.
3. If the VPS can't pull the image, GHCR created the package private. Make `ghcr.io/indy-center/moodle` public in the package's settings and re-run the workflow.
4. Do the three routing steps in [Routing](#routing).

`ENV_POSTGRES_PASSWORD` is only read when the database volume is first created. Changing the secret afterwards doesn't change the database's password, and Moodle can no longer connect.

Moodle idles at about 60 MB, and the database at about 25 MB. Twelve people loading their dashboards at once took it to about 225 MB. Course restores and big reports use more, up to PHP's 256 MB per request, which the container's 1.5 GB limit absorbs.

## Disclaimer

We are not affiliated with the FAA or any aviation governing body. This software is for flight simulation use on the [VATSIM](https://www.vatsim.net) network.
