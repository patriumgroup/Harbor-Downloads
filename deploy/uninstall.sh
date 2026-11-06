#!/usr/bin/env bash
# Remove Harbor's core programs and units while preserving tenant and host data.
set -euo pipefail
if [[ ${EUID} -ne 0 || ${1:-} != --confirm || $# -ne 1 ]]; then
  echo 'Usage: sudo bash deploy/uninstall.sh --confirm' >&2
  echo 'This removes Harbor programs and core units. It preserves accounts, databases, mail, configuration, logs, backups and Ubuntu packages.' >&2
  exit 2
fi

# Active proxy or mail routes need a deliberate operator change first. Removing
# Harbor behind those routes would otherwise leave working sites or mail broken.
if command -v nginx >/dev/null; then
  nginx_config=$(nginx -T 2>/dev/null) || { echo 'Fix NGINX configuration before uninstalling Harbor.' >&2; exit 1; }
  if grep -Eq 'proxy_pass[[:space:]]+http://harbor_(gateway|pgadmin)|/usr/local/share/harbor|/etc/harbor/nginx-|/etc/harbor/waf-sites/|/etc/harbor/php-sites/' <<<"${nginx_config}"; then
    echo 'Remove active Harbor panel, tool and website includes from NGINX and validate nginx -t first.' >&2
    exit 1
  fi
fi
exec 7>/run/harbor-package.lock
flock -n 7 || { echo 'A Harbor package operation is active; uninstall is unavailable.' >&2; exit 1; }
exec 8>/run/harbor-update.lock
flock -n 8 || { echo 'A Harbor update is active; uninstall is unavailable.' >&2; exit 1; }
exec 9>/run/harbor-release-manager.lock
flock -n 9 || { echo 'A Harbor release operation is active; uninstall is unavailable.' >&2; exit 1; }
for directory in /usr/local/share/harbor /usr/local/lib/harbor; do
  if [[ -L ${directory} ]]; then
    echo "Refusing to remove symlinked Harbor directory: ${directory}" >&2
    exit 1
  fi
done
if [[ -f /etc/postfix/main.cf ]] && grep -Eq '^[[:space:]]*(smtpd_milters|non_smtpd_milters)[[:space:]]*=.*harbor' /etc/postfix/main.cf; then
  echo 'Detach the Harbor mail Milter from Postfix and validate mail delivery first.' >&2
  exit 1
fi

units=(
  harbor-release-auto.timer harbor-web.socket harbor-web.service
  harbor-cert@.service
  harbor-agent.service harbor-terminal.service harbor-dns.socket
  harbor-dns.service harbor-filter.service harbor-signer.service
  harbor-pgadmin.socket harbor-pgadmin.service
  harbor-admin-pgadmin.socket harbor-admin-pgadmin.service
  harbor-spam-redis.service
)
for unit in "${units[@]}"; do
  if systemctl cat "${unit}" >/dev/null 2>&1; then
    systemctl disable --now "${unit}" >/dev/null 2>&1 || true
    if systemctl is-active --quiet "${unit}"; then
      echo "Cannot stop ${unit}; no Harbor files were removed." >&2
      exit 1
    fi
  fi
done

rm -f -- /usr/local/bin/harbor-agent /usr/local/bin/harbor-web \
  /usr/local/bin/harbor-terminal /usr/local/bin/harbor-dns \
  /usr/local/bin/harbor-signer /usr/local/bin/harbor-filter \
  /usr/local/bin/harborctl /usr/local/bin/harbor-package
rm -f -- /etc/systemd/system/harbor-agent.service \
  /etc/systemd/system/harbor-web.service /etc/systemd/system/harbor-web.socket \
  /etc/systemd/system/harbor-terminal.service \
  /etc/systemd/system/harbor-dns.service /etc/systemd/system/harbor-dns.socket \
  /etc/systemd/system/harbor-filter.service /etc/systemd/system/harbor-signer.service \
  /etc/systemd/system/harbor-package@.service \
  /etc/systemd/system/harbor-cert@.service \
  /etc/systemd/system/harbor-release@.service \
  /etc/systemd/system/harbor-release-auto.timer \
  /etc/systemd/system/harbor-pgadmin.service \
  /etc/systemd/system/harbor-pgadmin.socket \
  /etc/systemd/system/harbor-admin-pgadmin.service \
  /etc/systemd/system/harbor-admin-pgadmin.socket \
  /etc/systemd/system/harbor-spam-redis.service \
  /etc/logrotate.d/harbor-sites /etc/logrotate.d/harbor-panel \
  /etc/pam.d/harbor
for directory in /usr/local/share/harbor /usr/local/lib/harbor; do
  rm -rf -- "${directory}"
done
if [[ -f /etc/letsencrypt/renewal-hooks/deploy/harbor-nginx ]] && grep -Fxq 'exec /usr/local/lib/harbor/harbor-tls.py renew-deploy' /etc/letsencrypt/renewal-hooks/deploy/harbor-nginx; then
  rm -f -- /etc/letsencrypt/renewal-hooks/deploy/harbor-nginx
fi
systemctl daemon-reload
echo 'Harbor core programs and units removed. Native owners, SQL data, mail, optional tools, /etc/harbor, /var/lib/harbor, logs, backups and APT sources were preserved for review.'
