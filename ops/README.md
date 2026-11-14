# Eloq's server on oracle

Snapback 4 serves Eloq's sync at https://eloq.orbitlabs.studio (an A record in Vercel DNS to
oracle, 192.18.154.172), on the same ARM64 VPS as Flint, set up the same way.

- **Binary.** snapback4 0.4.53 built from expo/snapback PR #25 (`07ef490ed`, rusqlite 0.41.1,
  SQLite 3.54.1) for linux-arm64 in `rust:1.97-bookworm`, because npm ships no linux-arm64
  binary. Build it from a `git archive` of `snapback4/` without `reports/` and `metrics/` (keep
  the four `reports/` files the crates `include_str!`):
  `docker run --platform linux/arm64 -v "$PWD":/work -w /work rust:1.97-bookworm cargo build --release --locked -p snapback4`.
  Installed at `/opt/eloq/snapback4` with `/opt/eloq/schema.q`.
- **Data.** `/var/lib/eloq/deployment`, owned by the `eloq` system user, mode 0700.
- **Backend.** `eloq-snapback.service` on `127.0.0.1:4420`, production mode (password accounts, no dev doors).
- **Bridge.** `eloq-snapback-proxy.socket` on the traefik network's gateway, `172.26.0.1:4421`,
  forwarding to loopback (`systemd-socket-proxyd`).
- **Route.** `traefik-eloq.yml`, merged by hand into `/matrix/traefik/config/provider.yml`, which
  other services share: back it up, merge, never overwrite. Replace `ELOQ_HOST` with `eloq.orbitlabs.studio`. On 2026-11-14 the file had been rewritten
  with only Flowback's route (Flint was down): restore other services from their own committed
  fragments when that happens, and keep a dated backup beside the file before every edit.
- **Backups.** `eloq-backup.timer` at 04:20 UTC runs `/opt/eloq/backup.sh /var/backups/eloq`: it
  stops the backend, archives the whole deployment, starts it again, keeps 30 archives. Copy them
  off the server too; nothing does that yet.

## A new schema

```sh
scp snapback/schema.q oracle:/tmp/schema.q
ssh oracle 'sudo /opt/eloq/backup.sh /var/backups/eloq &&
  sudo install -m 644 /tmp/schema.q /opt/eloq/schema.q &&
  sudo systemctl stop eloq-snapback &&
  sudo -u eloq /opt/eloq/snapback4 deploy /var/lib/eloq/deployment --schema /opt/eloq/schema.q &&
  sudo systemctl start eloq-snapback'
```

## Check it

```sh
ssh oracle 'systemctl status eloq-snapback --no-pager; curl -s http://127.0.0.1:4420/auth/config'
```

## shared traefik routes (routes-guard/)

`/matrix/traefik/config/provider.yml` belongs to the matrix playbook in the multiplexer repo.
each playbook run rewrites it from that repo's inventory and drops every route the inventory
does not list (2026-11-14 08:06 and 16:22 UTC: eloq and flint went to 404).

`traefik-routes-guard.path` watches the file. after a rewrite, `merge-routes.py` merges every
fragment in `/etc/traefik-routes.d/*.yml` back in, and writes only when something is missing.

    sudo install -d -m 0755 /opt/traefik-routes-guard /etc/traefik-routes.d
    sudo install -m 0755 routes-guard/merge-routes.py /opt/traefik-routes-guard/
    sudo install -m 0644 routes-guard/fragments/*.yml /etc/traefik-routes.d/
    sudo install -m 0644 routes-guard/traefik-routes-guard.{service,path} /etc/systemd/system/
    sudo systemctl daemon-reload && sudo systemctl enable --now traefik-routes-guard.path

the flint fragments are copies of `ops/traefik-habits.yml` and `ops/mcp/traefik.fragment.yml`
in habit-system-fullstack. when flint changes its routes, copy them again.
