#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Usage: bash deploy/update.sh [--verify-only] RELEASE.tar.gz EXPECTED_SHA256' >&2
  exit 2
}

verify_only=false
if [[ ${1:-} == --verify-only ]]; then verify_only=true; shift; fi
[[ $# == 2 ]] || usage
archive=$1
expected=$2
[[ ${expected} =~ ^[0-9a-f]{64}$ ]] || { echo 'Expected SHA-256 must be 64 lowercase hex characters.' >&2; exit 2; }
[[ -f ${archive} && ! -L ${archive} ]] || { echo 'Release archive must be a regular file.' >&2; exit 1; }
actual=$(sha256sum -- "${archive}")
actual=${actual%% *}
[[ ${actual} == "${expected}" ]] || { echo 'Release SHA-256 does not match.' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
python3 "${script_dir}/release_bundle.py" verify "${archive}" >/dev/null
if ${verify_only}; then echo 'Release archive and manifest verified.'; exit 0; fi

[[ ${EUID} == 0 ]] || { echo 'Run the updater as root.' >&2; exit 1; }
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'This release supports Ubuntu 24.04 LTS amd64 only.' >&2; exit 1;
}
[[ -f /etc/harbor/harbor.env && -f /var/lib/harbor/admins.json ]] || {
  echo 'No existing Harbor installation found. Use the release installer for a fresh host.' >&2; exit 1;
}
exec 9>/run/harbor-update.lock
flock -n 9 || { echo 'Another Harbor update is running.' >&2; exit 1; }
umask 077
staging=$(mktemp -d /var/tmp/harbor-release.XXXXXXXX)
trap 'rm -rf -- "${staging}"' EXIT
release_dir=$(python3 "${script_dir}/release_bundle.py" extract "${archive}" "${staging}")
for binary in harbor-agent harbor-web harbor-terminal harbor-dns harbor-signer harbor-filter harborctl harbor-package; do
  if ! linkage=$(ldd "${release_dir}/build/${binary}" 2>&1) || [[ ${linkage} == *'not found'* ]]; then
    echo "Missing runtime library for ${binary}. Install the release prerequisites before updating." >&2
    exit 1
  fi
done

[[ ! -L /var/backups/harbor ]] || { echo 'Unsafe backup directory.' >&2; exit 1; }
install -d -o root -g root -m 0700 /var/backups/harbor
[[ $(stat -c '%u:%a' /var/backups/harbor) == 0:700 ]] || { echo 'Unsafe backup directory ownership or mode.' >&2; exit 1; }
backup=$(mktemp -d /var/backups/harbor/update.XXXXXXXX)
paths=(/etc/harbor /var/lib/harbor /usr/local/share/harbor /etc/pam.d/harbor)
for path in /usr/local/bin/harbor-* /usr/local/bin/harborctl \
            /etc/systemd/system/harbor-* /etc/logrotate.d/harbor-*; do
  [[ -e ${path} || -L ${path} ]] && paths+=("${path}")
done
tar -C / -czf "${backup}/state.tar.gz" -- "${paths[@]#/}"
chmod 0600 "${backup}/state.tar.gz"
printf '%s\n' "${expected}" >"${backup}/release.sha256"
chmod 0600 "${backup}/release.sha256"
echo "Harbor backup saved under ${backup} (root only)."

unset HARBOR_ADMIN_AUTH_MODE HARBOR_INITIAL_ADMIN_USER
if ! bash "${release_dir}/deploy/install.sh"; then
  echo "Update failed. Preserve ${backup}; inspect installer output before restoring or retrying." >&2
  exit 1
fi
echo 'Harbor update completed. Verify panel access and managed services before removing the backup.'
