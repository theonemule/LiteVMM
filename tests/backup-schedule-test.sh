#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mkdir -p "$T/vms/demo" "$T/disks/demo" "$T/backups" "$T/schedules" "$T/logs" "$T/jobs" "$T/cron.d" "$T/crontabs"
printf 'NAME=demo\nDISK_0_FILE=disk0.qcow2\nDISK_0_FORMAT=qcow2\nDISK_0_BUS=virtio\n' > "$T/vms/demo/vm.conf"
printf 'scheduled-backup-data\n' > "$T/disks/demo/disk0.qcow2"

cat > "$T/vmctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in status) printf 'stopped\n';; *) exit 2;; esac
MOCK
cat > "$T/vmbackupctl" <<MOCK
#!/usr/bin/env bash
exec bash "$ROOT/bin/vmbackupctl" "\$@"
MOCK
chmod +x "$T/vmctl" "$T/vmbackupctl"

common=(
  VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh"
  VM_ROOT="$T/vms" DISK_ROOT="$T/disks"
  VMAPI_BACKUP_ROOT="$T/backups"
  VMAPI_BACKUP_SCHEDULE_ROOT="$T/schedules"
  VMAPI_BACKUP_LOG_ROOT="$T/logs"
  VMAPI_BACKUP_JOB_ROOT="$T/jobs"
  VMAPI_BACKUP_CRONTAB="$T/crontabs/root"
  VMAPI_BACKUP_CRON_D_ROOT="$T/cron.d"
  VMAPI_BACKUP_SKIP_CRON_SERVICE=true
  VMAPI_BACKUPCTL="$T/vmbackupctl"
  VMCTL="$T/vmctl"
)

# Debian-family cron uses /etc/cron.d semantics: the user field is required.
env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=debian bash "$ROOT/bin/vmbackupctl" schedule demo '17 3 * * *' --label nightly --destination "$T/backups" --keep 2
cronfile="$T/cron.d/vmapi-backup-demo-nightly"
[[ -f $cronfile ]]
grep -qx 'SHELL=/bin/bash' "$cronfile"
grep -Eq '^17 3 \* \* \* root .*/vmbackupctl scheduled-run demo nightly >> .*demo-nightly.log 2>&1$' "$cronfile"
[[ $(stat -c %a "$cronfile") == 644 ]]

# Listing schedules is also a reconciliation point. An upgraded host with saved
# schedules but missing runtime cron entries must repair them automatically.
rm -f "$cronfile"
list=$(env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=debian bash "$ROOT/bin/vmbackupctl" schedules)
[[ -f $cronfile ]]
[[ $list == *'"vm":"demo"'* && $list == *'"scheduler_active":true'* ]]

# The cron entry point reloads the saved policy and passes the exact backup
# options to the tracked-job launcher. Override cmd_start so this stays a pure
# scheduler test and does not depend on a system vmapi account.
run_args=$(env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=debian ROOT="$ROOT" bash -c '
  source <(awk "/^case / {exit} {print}" "$ROOT/bin/vmbackupctl")
  cmd_start(){ printf "%s\n" "$*"; }
  cmd_scheduled_run demo nightly
')
[[ $run_args == *'demo --label nightly'* ]]
[[ $run_args == *"--destination $T/backups"* ]]
[[ $run_args == *'--keep 2'* ]]

# Alpine/BusyBox cron uses root's user crontab and must not contain a user field.
env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=alpine bash "$ROOT/bin/vmbackupctl" schedule demo '23 4 * * 1' --label weekly --destination "$T/backups"
grep -Eq '^23 4 \* \* 1 .*/vmbackupctl scheduled-run demo weekly >> .*demo-weekly.log 2>&1 # vmapi-backup:demo:weekly$' "$T/crontabs/root"
! grep -Eq '^23 4 \* \* 1 root ' "$T/crontabs/root"

# Service state is determined through OpenRC itself, not pgrep. Minimal Alpine
# installs do not necessarily provide procps/pgrep even though crond is healthy.
mkdir -p "$T/mockbin"
cat > "$T/mockbin/rc-service" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == crond ]]
case "$2" in
  start|restart) : > "$VMAPI_CRON_STATE";;
  status) [[ -f $VMAPI_CRON_STATE ]];;
  *) exit 2;;
esac
MOCK
cat > "$T/mockbin/rc-update" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$VMAPI_CRON_UPDATE_LOG"
MOCK
cat > "$T/mockbin/crond" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$T/mockbin/rc-service" "$T/mockbin/rc-update" "$T/mockbin/crond"
rm -f "$T/crond.state" "$T/rc-update.log"
runtime_list=$(env "${common[@]}" VMAPI_BACKUP_SKIP_CRON_SERVICE=false VMAPI_BACKUP_CRON_STYLE=alpine \
  VMAPI_CRON_STATE="$T/crond.state" VMAPI_CRON_UPDATE_LOG="$T/rc-update.log" PATH="$T/mockbin:$PATH" \
  bash "$ROOT/bin/vmbackupctl" schedules)
[[ -f $T/crond.state ]]
grep -qx 'add crond default' "$T/rc-update.log"
[[ $runtime_list == *'"scheduler_active":true'* ]]

# Rebuild all runtime entries from saved schedule definitions, then remove one.
: > "$T/crontabs/root"
env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=alpine bash "$ROOT/bin/vmbackupctl" sync-schedules
grep -q '# vmapi-backup:demo:nightly' "$T/crontabs/root"
grep -q '# vmapi-backup:demo:weekly' "$T/crontabs/root"
env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=alpine bash "$ROOT/bin/vmbackupctl" unschedule demo weekly
! grep -q '# vmapi-backup:demo:weekly' "$T/crontabs/root"
[[ ! -e $T/schedules/demo-weekly ]]

# Cron input is data, never shell syntax.
if env "${common[@]}" VMAPI_BACKUP_CRON_STYLE=debian bash "$ROOT/bin/vmbackupctl" schedule demo '0 2 * * *; touch /tmp/nope' --label bad --destination "$T/backups" >/dev/null 2>&1; then
  echo 'unsafe cron expression was accepted' >&2; exit 1
fi

echo 'backup scheduler runtime: PASS'
