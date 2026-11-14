#!/bin/sh
set -eu
# run on the server as root: archives the whole stopped deployment (store, wal, releases, assets).
# copying only store.sqlite from a running server is not a backup.
backup_dir=${1:?usage: backup.sh /absolute/backup/directory}
case "$backup_dir" in /*) ;; *) exit 2 ;; esac
install -d -m 700 "$backup_dir"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive="$backup_dir/eloq-$stamp.tar.gz"
systemctl stop eloq-snapback
trap 'systemctl start eloq-snapback' EXIT HUP INT TERM
tar -czf "$archive" -C /var/lib/eloq deployment
chmod 600 "$archive"
# keep the newest 30
ls -1t "$backup_dir"/eloq-*.tar.gz 2>/dev/null | tail -n +31 | xargs -r rm -f
printf '%s\n' "$archive"
