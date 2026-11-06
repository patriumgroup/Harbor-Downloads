#!/usr/bin/env bash
# Optional, explicit Ubuntu 24.04 database-tools installation. Review first.
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Run as root on your Ubuntu test host.' >&2; exit 1; }
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 ]] || { echo 'Ubuntu 24.04 required.' >&2; exit 1; }
tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ -f /etc/harbor/harbor.env ]] || { echo 'Install Harbor first.' >&2; exit 1; }
printf 'phpmyadmin phpmyadmin/dbconfig-install boolean false\n' | debconf-set-selections
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y phpmyadmin php8.3-fpm php8.3-mysql php8.3-mbstring php8.3-xml python3-venv
for service_user in harbor-dbtools harbor-pgadmin harbor-admin-dbtools harbor-admin-pgadmin; do
  if ! getent passwd "${service_user}" >/dev/null; then
    useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin "${service_user}"
  else
    [[ $(id -u "${service_user}") -ne 0 && $(getent passwd "${service_user}" | cut -d: -f7) == /usr/sbin/nologin ]] || { echo 'Unsafe existing tool account.' >&2; exit 1; }
  fi
done
for service_user in harbor-dbtools harbor-pgadmin harbor-admin-dbtools harbor-admin-pgadmin; do usermod -a -G harbor-tools "${service_user}"; done
install -d -o harbor-dbtools -g harbor-dbtools -m 0700 /var/lib/harbor-phpmyadmin /var/lib/harbor-phpmyadmin/tmp /var/lib/harbor-phpmyadmin/sessions
install -d -o harbor-pgadmin -g harbor-pgadmin -m 0700 /var/lib/harbor-pgadmin /var/lib/harbor-pgadmin/sessions /var/lib/harbor-pgadmin/storage
install -d -o harbor-admin-dbtools -g harbor-admin-dbtools -m 0700 /var/lib/harbor-admin-phpmyadmin /var/lib/harbor-admin-phpmyadmin/tmp /var/lib/harbor-admin-phpmyadmin/sessions
install -d -o harbor-admin-pgadmin -g harbor-admin-pgadmin -m 0700 /var/lib/harbor-admin-pgadmin /var/lib/harbor-admin-pgadmin/sessions /var/lib/harbor-admin-pgadmin/storage
install -d -o root -g root -m 0755 /etc/phpmyadmin/conf.d /usr/local/share/harbor/database-tools
install -o root -g root -m 0644 "${tools_dir}/phpmyadmin.php" /etc/phpmyadmin/conf.d/harbor.php
install -o root -g root -m 0644 "${tools_dir}/phpmyadmin-pool.conf" /etc/php/8.3/fpm/pool.d/harbor-phpmyadmin.conf
install -o root -g root -m 0644 "${tools_dir}/admin-phpmyadmin-pool.conf" /etc/php/8.3/fpm/pool.d/harbor-admin-phpmyadmin.conf
if [[ ! -f /etc/harbor/phpmyadmin.secret ]]; then
  (umask 0077; openssl rand -hex 32 >/etc/harbor/phpmyadmin.secret)
fi
chown root:harbor-dbtools /etc/harbor/phpmyadmin.secret
chmod 0640 /etc/harbor/phpmyadmin.secret
if [[ ! -f /etc/harbor/admin-phpmyadmin.secret ]]; then (umask 0077; openssl rand -hex 32 >/etc/harbor/admin-phpmyadmin.secret); fi
chown root:harbor-admin-dbtools /etc/harbor/admin-phpmyadmin.secret
chmod 0640 /etc/harbor/admin-phpmyadmin.secret
python3 -m venv /opt/harbor-pgadmin
/opt/harbor-pgadmin/bin/pip install --requirement "${tools_dir}/requirements.txt"
pgadmin_package=/opt/harbor-pgadmin/lib/python3.12/site-packages/pgadmin4
[[ -f ${pgadmin_package}/pgAdmin4.py && -f ${pgadmin_package}/setup.py ]] || { echo 'Unexpected pgAdmin package layout; stop and review.' >&2; exit 1; }
install -o root -g root -m 0644 "${tools_dir}/config_local.py" "${pgadmin_package}/config_local.py"
install -o root -g root -m 0644 "${tools_dir}/harbor_pgadmin.py" "${tools_dir}/pg_sso.py" "${tools_dir}/sso-client.php" "${tools_dir}/signon.php" /usr/local/share/harbor/database-tools/
if [[ ! -f /etc/harbor/pgadmin.env ]]; then
  (umask 0077; for secret_name in HARBOR_PGADMIN_PROXY_SECRET HARBOR_PGADMIN_SECRET_KEY HARBOR_PGADMIN_PASSWORD_SALT; do
    printf '%s=' "${secret_name}"; openssl rand -hex 32
  done >/etc/harbor/pgadmin.env)
fi
chmod 0600 /etc/harbor/pgadmin.env
set -a
source /etc/harbor/pgadmin.env
set +a
[[ ${HARBOR_PGADMIN_PROXY_SECRET} =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid pgAdmin proxy secret.' >&2; exit 1; }
(umask 0077; printf 'proxy_set_header X-Harbor-Proxy-Secret "%s";\n' "${HARBOR_PGADMIN_PROXY_SECRET}" >/etc/harbor/pgadmin-proxy-header.conf)
if [[ ! -f /var/lib/harbor-pgadmin/pgadmin4.db ]]; then
  # This unreachable bootstrap identity only initializes pgAdmin's schema.
  # Webserver-only auth accepts strict native usernames, never this email.
  PGADMIN_SETUP_EMAIL=bootstrap@localhost PGADMIN_SETUP_PASSWORD="$(openssl rand -hex 32)" \
    runuser --preserve-environment -u harbor-pgadmin -- /opt/harbor-pgadmin/bin/python "${pgadmin_package}/setup.py" setup-db
fi
if [[ ! -f /etc/harbor/admin-pgadmin.env ]]; then
  (umask 0077; for secret_name in HARBOR_PGADMIN_PROXY_SECRET HARBOR_PGADMIN_SECRET_KEY HARBOR_PGADMIN_PASSWORD_SALT; do
    printf '%s=' "${secret_name}"; openssl rand -hex 32
  done >/etc/harbor/admin-pgadmin.env)
fi
chown root:root /etc/harbor/admin-pgadmin.env
chmod 0600 /etc/harbor/admin-pgadmin.env
set -a
source /etc/harbor/admin-pgadmin.env
set +a
[[ ${HARBOR_PGADMIN_PROXY_SECRET} =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid administrator pgAdmin proxy secret.' >&2; exit 1; }
(umask 0077; printf 'proxy_set_header X-Harbor-Proxy-Secret "%s";\n' "${HARBOR_PGADMIN_PROXY_SECRET}" >/etc/harbor/admin-pgadmin-proxy-header.conf)
if [[ ! -f /var/lib/harbor-admin-pgadmin/pgadmin4.db ]]; then
  HARBOR_PGADMIN_ROLE=admin PGADMIN_SETUP_EMAIL=bootstrap-admin@localhost PGADMIN_SETUP_PASSWORD="$(openssl rand -hex 32)" \
    runuser --preserve-environment -u harbor-admin-pgadmin -- /opt/harbor-pgadmin/bin/python "${pgadmin_package}/setup.py" setup-db
fi
"/usr/local/bin/harbor-agent" --provision-admin-tools
install -o root -g root -m 0644 "${tools_dir}/harbor-pgadmin.service" /etc/systemd/system/
install -o root -g root -m 0644 "${tools_dir}/harbor-pgadmin.socket" /etc/systemd/system/
install -o root -g root -m 0644 "${tools_dir}/harbor-admin-pgadmin.service" /etc/systemd/system/
install -o root -g root -m 0644 "${tools_dir}/harbor-admin-pgadmin.socket" /etc/systemd/system/
php-fpm8.3 -t
systemctl daemon-reload
echo 'Tool files installed. Complete the nginx-locations.conf.example hostname and include it in your HTTPS vhost.'
echo 'Validate NGINX, set HARBOR_DATABASE_TOOLS=1 in the protected Harbor environment, then follow https://github.com/patriumgroup/Harbor/blob/main/docs/TENANCY.md.'
echo 'The script does not enable either pgAdmin instance or reload your public proxy.'
