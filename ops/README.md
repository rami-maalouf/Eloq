# Eloq's server on oracle

Snapback 4 serves Eloq's sync on the same ARM64 VPS as Flint, set up the same way.

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
  other services share: back it up, merge, never overwrite. Replace `ELOQ_HOST`.
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
