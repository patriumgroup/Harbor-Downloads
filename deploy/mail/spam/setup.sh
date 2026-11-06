#!/usr/bin/env bash
# Explicit optional spam scanner installation on a dedicated Ubuntu mail host.
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run as root.' >&2; exit 1; }
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 ]] || { echo 'Ubuntu 24.04 required.' >&2; exit 1; }
[[ -x /usr/local/bin/harbor-filter ]] || { echo 'Install the updated Harbor core first.' >&2; exit 1; }
spam_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y rspamd redis-server dovecot-sieve
install -d -o root -g root -m 0755 /etc/harbor/mail /etc/rspamd/local.d
backup_dir=$(mktemp -d /var/backups/harbor-spam-XXXXXXXX)
for name in worker-normal.inc worker-controller.inc worker-proxy.inc redis.conf; do
  if [[ -f /etc/rspamd/local.d/${name} ]]; then cp -a -- "/etc/rspamd/local.d/${name}" "${backup_dir}/"; fi
done
printf 'bind_socket = "127.0.0.1:11333";\ncount = 2;\n' >/etc/rspamd/local.d/worker-normal.inc
printf 'enabled = false;\n' >/etc/rspamd/local.d/worker-controller.inc
printf 'enabled = false;\n' >/etc/rspamd/local.d/worker-proxy.inc
printf 'servers = "/run/harbor-spam-redis/redis.sock";\n' >/etc/rspamd/local.d/redis.conf
install -o root -g root -m 0644 "${spam_dir}/harbor.sieve" /etc/harbor/mail/harbor.sieve
sievec /etc/harbor/mail/harbor.sieve
rspamadm configtest
install -o root -g root -m 0644 "${spam_dir}/redis.conf" /etc/harbor/mail/redis.conf
install -o root -g root -m 0644 "${spam_dir}/harbor-spam-redis.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now harbor-spam-redis rspamd
systemctl restart rspamd
echo "Spam scanner configured on loopback. Backup: ${backup_dir}. Run the reviewed mail configuration procedure next."
