#!/usr/bin/env bash
# Explicit Roundcube setup; replaces its configuration with a protected backup.
set -euo pipefail
[[ ${EUID} -eq 0 && ${1:-} == --replace-webmail-config ]] || { echo 'Usage: sudo bash deploy/webmail/setup.sh --replace-webmail-config' >&2; exit 1; }
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 ]] || { echo 'Ubuntu 24.04 required.' >&2; exit 1; }
[[ -f /etc/harbor/mail/ready && -f /etc/harbor/tool-sso.secret ]] || { echo 'Configure the updated core and local mail first.' >&2; exit 1; }
webmail_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
printf 'roundcube-core roundcube/dbconfig-install boolean false\n' | debconf-set-selections
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y roundcube-core roundcube-sqlite3 php8.3-fpm php8.3-sqlite3 php8.3-intl php8.3-mbstring php8.3-xml sqlite3
if ! getent passwd harbor-roundcube >/dev/null; then useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin harbor-roundcube; fi
[[ $(id -u harbor-roundcube) -ne 0 && $(getent passwd harbor-roundcube | cut -d: -f7) == /usr/sbin/nologin ]] || { echo 'Unsafe webmail identity.' >&2; exit 1; }
usermod -a -G harbor-tools harbor-roundcube
install -d -o harbor-roundcube -g harbor-roundcube -m 0700 /var/lib/harbor-roundcube /var/lib/harbor-roundcube/tmp /var/lib/harbor-roundcube/logs /var/lib/harbor-roundcube/sessions
install -d -o root -g root -m 0755 /usr/local/share/harbor/database-tools /usr/share/roundcube/plugins/harbor_sso
install -o root -g root -m 0644 "${webmail_dir}/../database-tools/sso-client.php" /usr/local/share/harbor/database-tools/
install -o root -g root -m 0644 "${webmail_dir}/harbor_sso.php" /usr/share/roundcube/plugins/harbor_sso/
# Ubuntu enables packaged plugins through links in its separate runtime tree.
plugin_link=/var/lib/roundcube/plugins/harbor_sso
if [[ -L ${plugin_link} ]]; then
  [[ $(readlink -f "${plugin_link}") == /usr/share/roundcube/plugins/harbor_sso ]] || { echo 'Unexpected existing SSO plugin link.' >&2; exit 1; }
elif [[ -e ${plugin_link} ]]; then
  echo 'Unexpected existing SSO plugin path.' >&2; exit 1
else
  ln -s /usr/share/roundcube/plugins/harbor_sso "${plugin_link}"
fi
backup_dir=$(mktemp -d /var/backups/harbor-roundcube-XXXXXXXX)
cp -a -- /etc/roundcube/config.inc.php "${backup_dir}/"
install -o root -g harbor-roundcube -m 0640 "${webmail_dir}/config.inc.php" /etc/roundcube/config.inc.php
if [[ ! -f /etc/harbor/roundcube.secret ]]; then (umask 0077; openssl rand -hex 12 >/etc/harbor/roundcube.secret); fi
chown root:harbor-roundcube /etc/harbor/roundcube.secret; chmod 0640 /etc/harbor/roundcube.secret
if [[ ! -f /var/lib/harbor-roundcube/roundcube.sqlite ]]; then
  [[ -f /usr/share/roundcube/SQL/sqlite.initial.sql ]] || { echo 'Review installed Roundcube schema location.' >&2; exit 1; }
  runuser -u harbor-roundcube -- sqlite3 /var/lib/harbor-roundcube/roundcube.sqlite < /usr/share/roundcube/SQL/sqlite.initial.sql
fi
sed -e 's/harbor-phpmyadmin/harbor-roundcube/g' -e 's/harbor-dbtools/harbor-roundcube/g' -e 's|chdir = /usr/share/phpmyadmin|chdir = /var/lib/roundcube|' -e 's|php_admin_value\[open_basedir\].*|php_admin_value[open_basedir] = /var/lib/roundcube:/usr/share/roundcube:/usr/share/php:/usr/share/javascript:/usr/share/nodejs:/etc/roundcube:/etc/harbor:/var/lib/harbor-roundcube:/run/harbor-agent:/usr/local/share/harbor/database-tools:/tmp:/etc/ssl/certs|' "${webmail_dir}/../database-tools/phpmyadmin-pool.conf" >/etc/php/8.3/fpm/pool.d/harbor-roundcube.conf
php-fpm8.3 -t
echo "Roundcube files installed. Backup: ${backup_dir}. Add the reviewed NGINX locations, set HARBOR_WEBMAIL=1, and restart Harbor/FPM after validating the proxy."
