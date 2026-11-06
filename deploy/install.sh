#!/usr/bin/env bash
set -euo pipefail
if [[ ${EUID} -ne 0 ]]; then echo 'Run this installer as root.' >&2; exit 1; fi
source /etc/os-release
if [[ ${ID} != ubuntu || ${VERSION_ID} != 24.04 ]]; then
  echo 'This release targets Ubuntu 24.04 LTS. Review dependencies before adapting to another release.' >&2; exit 1
fi
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
install_progress() {
  printf 'Harbor: %s\n' "$1"
  if [[ ${HARBOR_INSTALL_PROGRESS_FD:-} == 3 ]]; then printf '    %s\n' "$1" >&3; fi
}
first_install=0
if [[ ! -e /etc/harbor/harbor.env ]]; then first_install=1; fi
if [[ ${first_install} == 1 ]]; then
  server_fqdn=${HARBOR_SERVER_FQDN:-}
  if [[ -z ${server_fqdn} && -t 0 ]]; then read -r -p 'Hosting server FQDN (for example panel.example.com): ' server_fqdn; fi
  python3 - "${server_fqdn}" <<'PY'
import ipaddress,re,sys
host=sys.argv[1]
if len(host)>253 or not re.fullmatch(r'[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+',host) or any(len(part)>63 for part in host.split('.')):
    sys.exit('Set HARBOR_SERVER_FQDN to a lowercase, complete DNS hostname.')
try: ipaddress.ip_address(host)
except ValueError: pass
else: sys.exit('HARBOR_SERVER_FQDN must be a DNS hostname, not an IP address.')
PY
  panel_ip=${HARBOR_PANEL_IP:-$(hostname -I 2>/dev/null | python3 -c 'import ipaddress,sys; print(next((value for value in sys.stdin.read().split() if value.count(".")==3 and ipaddress.ip_address(value).version==4),""))')}
  [[ -n ${panel_ip} ]] || { echo 'Set HARBOR_PANEL_IP to a server IPv4 address for fallback panel access.' >&2; exit 1; }
  if [[ -n ${panel_ip} ]]; then
    python3 - "${panel_ip}" <<'PY'
import ipaddress,sys
try: ipaddress.IPv4Address(sys.argv[1])
except ValueError: sys.exit('HARBOR_PANEL_IP must be one IPv4 address.')
PY
  fi
  acme_email=${HARBOR_ACME_EMAIL:-}
  if [[ -z ${acme_email} && -t 0 ]]; then read -r -p "Let's Encrypt contact email (blank to configure later): " acme_email; fi
  if [[ -n ${acme_email} ]]; then
    python3 - "${acme_email}" <<'PY'
import re,sys
if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',sys.argv[1]): sys.exit('Invalid ACME contact email.')
PY
  fi
fi
if [[ -f /etc/harbor/harbor.env ]] && command -v nginx >/dev/null; then
  python3 - <<'PY'
import re,subprocess,sys
config=subprocess.run(['nginx','-T'],capture_output=True,text=True)
if config.returncode:
    sys.exit('Existing NGINX configuration must pass nginx -t before upgrading Harbor.')
if re.search(r'^\s*proxy_pass\s+http://127\.0\.0\.1:(?:8088|5050)(?:[;/]|$)',config.stdout,re.MULTILINE):
    sys.exit('Update all active Harbor NGINX upstreams to the protected Unix sockets before upgrading. See https://github.com/patriumgroup/Harbor#readme.')
PY
fi
if [[ ! -x ${project_dir}/build/harbor-agent || ! -x ${project_dir}/build/harbor-web || ! -x ${project_dir}/build/harbor-terminal || ! -x ${project_dir}/build/harbor-dns || ! -x ${project_dir}/build/harbor-filter || ! -x ${project_dir}/build/harbor-signer || ! -x ${project_dir}/build/harborctl || ! -x ${project_dir}/build/harbor-package ]]; then
  echo 'Build and test the project first. See https://github.com/patriumgroup/Harbor#readme.' >&2; exit 1
fi
install_progress 'Create restricted service identities and directories'
if ! getent group harbor-tools >/dev/null; then groupadd --system harbor-tools; fi
if ! getent passwd harbor-filter >/dev/null; then useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin harbor-filter; fi
[[ $(id -u harbor-filter) -ne 0 && $(getent passwd harbor-filter | cut -d: -f7) == /usr/sbin/nologin ]] || { echo 'Unsafe filter identity.' >&2; exit 1; }
if ! getent passwd harbor-signer >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin harbor-signer
fi
[[ $(id -u harbor-signer) -ne 0 && $(id -g harbor-signer) -ne 0 && $(getent passwd harbor-signer | cut -d: -f7) == /usr/sbin/nologin ]] || { echo 'Unsuitable signing service identity.' >&2; exit 1; }
install -d -o root -g harbor-signer -m 0750 /var/lib/harbor-dkim
if ! getent passwd harbor-dns >/dev/null; then
  useradd --system --user-group --home-dir /var/lib/harbor-dns --shell /usr/sbin/nologin harbor-dns
fi
[[ $(id -u harbor-dns) -ne 0 && $(getent passwd harbor-dns | cut -d: -f7) == /usr/sbin/nologin ]] || { echo 'Unsuitable DNS service identity.' >&2; exit 1; }
if ! getent passwd harbor >/dev/null; then
  useradd --system --user-group --home-dir /nonexistent --shell /usr/sbin/nologin harbor
else
  [[ $(id -u harbor) -ne 0 && $(getent passwd harbor | cut -d: -f7) == /usr/sbin/nologin ]] || {
    echo 'Existing harbor account is unsuitable; refusing to reuse it.' >&2; exit 1;
  }
fi
install_progress 'Install Harbor binaries, runtime assets and systemd units'
install -d -o root -g root -m 0755 /usr/local/share/harbor/web /usr/local/lib/harbor /etc/harbor
install -d -o root -g root -m 0700 /var/lib/harbor
install -d -o root -g root -m 0755 /srv/harbor-sites /var/www/harbor-acme
install -d -o root -g root -m 0755 /usr/local/share/harbor/web/vendor
install -o root -g root -m 0644 "${project_dir}/LICENSE" "${project_dir}/THIRD_PARTY_NOTICES.txt" /usr/local/share/harbor/
install -o root -g root -m 0755 "${project_dir}/build/harbor-agent" "${project_dir}/build/harbor-web" "${project_dir}/build/harbor-terminal" "${project_dir}/build/harbor-dns" "${project_dir}/build/harbor-signer" "${project_dir}/build/harbor-filter" "${project_dir}/build/harborctl" "${project_dir}/build/harbor-package" /usr/local/bin/
install -o root -g root -m 0644 "${project_dir}"/web/{index.html,app.js,panel-views.js,admins.js,updates.js,styles.css,mark.svg} /usr/local/share/harbor/web/
install -o root -g root -m 0644 "${project_dir}"/web/vendor/* /usr/local/share/harbor/web/vendor/
install -o root -g root -m 0755 "${project_dir}"/deploy/{release_manager.py,release_bundle.py,update.sh,install-release.sh,uninstall.sh,php-repository.sh,harbor-tls.py} /usr/local/lib/harbor/
install -o root -g root -m 0644 "${project_dir}/deploy/php-ppa.pref" /usr/local/lib/harbor/php-ppa.pref
install -o root -g root -m 0644 "${project_dir}"/deploy/harbor-{agent,web,terminal,signer,filter}.service /etc/systemd/system/
install -o root -g root -m 0644 "${project_dir}"/deploy/harbor-dns.{socket,service} /etc/systemd/system/
install -o root -g root -m 0644 "${project_dir}/deploy/harbor-web.socket" /etc/systemd/system/
install -o root -g root -m 0644 "${project_dir}/deploy/harbor-package@.service" /etc/systemd/system/
install -o root -g root -m 0644 "${project_dir}/deploy/harbor-cert@.service" /etc/systemd/system/
install -o root -g root -m 0644 "${project_dir}/deploy/harbor-release@.service" "${project_dir}/deploy/harbor-release-auto.timer" /etc/systemd/system/
install -d -o root -g root -m 0755 /usr/local/share/harbor/security
install -o root -g root -m 0644 "${project_dir}/deploy/security/harbor-panel.conf" "${project_dir}/deploy/security/harbor.local" /usr/local/share/harbor/security/
install -o root -g root -m 0644 "${project_dir}/deploy/security/nginx-waf-test.conf" /usr/local/share/harbor/security/
install -o root -g root -m 0644 "${project_dir}/deploy/security/harbor-sites.logrotate" /etc/logrotate.d/harbor-sites
install -o root -g root -m 0644 "${project_dir}/deploy/security/harbor-panel.logrotate" /etc/logrotate.d/harbor-panel
install -d -o root -g root -m 0755 /var/log/nginx
for log_name in harbor-panel-access.json harbor-panel-error.log; do
  log_path="/var/log/nginx/${log_name}"
  [[ ! -L ${log_path} && ( ! -e ${log_path} || -f ${log_path} ) ]] || { echo "Unsafe panel log: ${log_path}" >&2; exit 1; }
  if [[ ! -e ${log_path} ]]; then install -o root -g root -m 0640 /dev/null "${log_path}"; fi
  [[ $(stat -c '%h' "${log_path}") == '1' ]] || { echo "Unsafe panel log link count: ${log_path}" >&2; exit 1; }
  chown root:root "${log_path}"
  chmod 0640 "${log_path}"
done
install -o root -g root -m 0644 "${project_dir}/deploy/security/harbor-http.conf" /etc/harbor/nginx-http.conf
install -o root -g root -m 0644 "${project_dir}/deploy/security/harbor-basic.conf" /etc/harbor/nginx-basic.conf
install -o root -g root -m 0644 "${project_dir}/deploy/harbor.pam" /etc/pam.d/harbor
if [[ ! -e /var/lib/harbor/owners.json ]]; then
  (umask 0077; printf '{"owners":{},"domains":[]}\n' > /var/lib/harbor/owners.json)
fi
if [[ ! -e /etc/harbor/database-users.json ]]; then
  printf '{}\n' > /etc/harbor/database-users.json
  chmod 0644 /etc/harbor/database-users.json
fi
if [[ ! -e /etc/harbor/harbor.env ]]; then
  umask 0077
  printf 'HARBOR_ORIGIN=https://%s\n' "${server_fqdn}" >/etc/harbor/harbor.env
  if [[ -n ${panel_ip} ]]; then printf 'HARBOR_IP_ORIGIN=https://%s\n' "${panel_ip}" >>/etc/harbor/harbor.env; fi
fi
if [[ ${first_install} == 1 && -n ${acme_email} ]]; then
  (umask 0077; printf '%s\n' "${acme_email}" >/etc/harbor/acme-email)
  chown root:root /etc/harbor/acme-email; chmod 0600 /etc/harbor/acme-email
fi
chown root:root /etc/harbor/harbor.env
chmod 0600 /etc/harbor/harbor.env
install_progress 'Initialize administrator account and local secrets'
if [[ ! -e /var/lib/harbor/admins.json ]]; then
  initial_admin=${HARBOR_INITIAL_ADMIN_USER:-admin}
  legacy_token=$(sed -n 's/^HARBOR_ADMIN_TOKEN=//p' /etc/harbor/harbor.env)
  if [[ -n ${legacy_token} ]]; then
    admin_mode=token
    admin_credential=${legacy_token}
    echo 'Migrating the existing administrator token to the first super admin account.'
  else
    admin_mode=${HARBOR_ADMIN_AUTH_MODE:-}
    if [[ -z ${admin_mode} && -t 0 ]]; then
      read -r -p 'Administrator login mode (token/password) [token]: ' admin_mode
    fi
    admin_mode=${admin_mode:-token}
    case ${admin_mode} in
      token)
        admin_credential=$(openssl rand -hex 32)
        ;;
      password)
        admin_credential=$(openssl rand -hex 32)
        ;;
      *) echo 'Choose token or password for administrator login.' >&2; exit 1 ;;
    esac
  fi
  printf '%s\n%s\n%s\n' "${admin_mode}" "${initial_admin}" "${admin_credential}" | /usr/local/bin/harbor-agent --init-admin
  if [[ ${admin_mode} == token ]]; then
    (umask 0077; printf '%s\n' "${admin_credential}" >/etc/harbor/initial-admin-token)
    chown root:root /etc/harbor/initial-admin-token
    chmod 0600 /etc/harbor/initial-admin-token
    echo 'The initial token is in /etc/harbor/initial-admin-token (root only).'
  else
    (umask 0077; printf '%s\n' "${admin_credential}" >/etc/harbor/initial-admin-password)
    chown root:root /etc/harbor/initial-admin-password
    chmod 0600 /etc/harbor/initial-admin-password
    echo 'The initial password is in /etc/harbor/initial-admin-password (root only).'
  fi
  unset admin_credential legacy_token
fi
if [[ -n ${HARBOR_ADMIN_AUTH_MODE:-} ]]; then
  case ${HARBOR_ADMIN_AUTH_MODE} in token|password) ;; *) echo 'Choose token or password for administrator login.' >&2; exit 1 ;; esac
  current_mode=$(/usr/local/bin/harbor-agent --admin-mode)
  if [[ ${current_mode} != "${HARBOR_ADMIN_AUTH_MODE}" ]]; then
    if [[ ${HARBOR_ADMIN_AUTH_MODE} == token ]]; then
      admin_credential=$(openssl rand -hex 32)
    else
      admin_credential=$(openssl rand -hex 32)
    fi
    printf '%s\n%s\n' "${HARBOR_ADMIN_AUTH_MODE}" "${admin_credential}" | /usr/local/bin/harbor-agent --change-admin-mode
    if [[ ${HARBOR_ADMIN_AUTH_MODE} == token ]]; then
      (umask 0077; printf '%s\n' "${admin_credential}" >/etc/harbor/initial-admin-token)
      chown root:root /etc/harbor/initial-admin-token
      chmod 0600 /etc/harbor/initial-admin-token
      rm -f -- /etc/harbor/initial-admin-password
      echo 'The new super admin token is in /etc/harbor/initial-admin-token (root only).'
    else
      (umask 0077; printf '%s\n' "${admin_credential}" >/etc/harbor/initial-admin-password)
      chown root:root /etc/harbor/initial-admin-password
      chmod 0600 /etc/harbor/initial-admin-password
      rm -f -- /etc/harbor/initial-admin-token
      echo 'The new super admin password is in /etc/harbor/initial-admin-password (root only).'
    fi
    unset admin_credential
  fi
fi
if grep -q '^HARBOR_ADMIN_TOKEN=' /etc/harbor/harbor.env; then sed -i '/^HARBOR_ADMIN_TOKEN=/d' /etc/harbor/harbor.env; fi
if ! grep -q '^HARBOR_PROXY_SECRET=' /etc/harbor/harbor.env; then
  { printf '\nHARBOR_PROXY_SECRET='; openssl rand -hex 32; } >>/etc/harbor/harbor.env
fi
proxy_secret=$(sed -n 's/^HARBOR_PROXY_SECRET=//p' /etc/harbor/harbor.env)
[[ ${proxy_secret} =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid or duplicate HARBOR_PROXY_SECRET.' >&2; exit 1; }
(umask 0077; printf 'proxy_set_header X-Harbor-Proxy "%s";\nproxy_set_header X-Harbor-Client-IP $remote_addr;\n' "${proxy_secret}" >/etc/harbor/nginx-proxy-secret.conf)
chown root:root /etc/harbor/nginx-proxy-secret.conf
chmod 0600 /etc/harbor/nginx-proxy-secret.conf
if [[ ! -f /etc/harbor/tool-sso.secret ]]; then (umask 0077; openssl rand -hex 32 >/etc/harbor/tool-sso.secret); fi
chown root:root /etc/harbor/tool-sso.secret; chmod 0600 /etc/harbor/tool-sso.secret
sso_secret=$(cat /etc/harbor/tool-sso.secret)
[[ ${sso_secret} =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid SSO secret.' >&2; exit 1; }
if grep -q '^HARBOR_TOOL_SSO_SECRET=' /etc/harbor/harbor.env; then sed -i '/^HARBOR_TOOL_SSO_SECRET=/d' /etc/harbor/harbor.env; fi
printf '\nHARBOR_TOOL_SSO_SECRET=%s\n' "${sso_secret}" >>/etc/harbor/harbor.env
install_progress 'Configure Ubuntu packages and repositories'
systemctl daemon-reload
bash /usr/local/lib/harbor/php-repository.sh
"/usr/local/bin/harbor-package" install-nginx
systemctl enable --now nginx.service
DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
install -d -o root -g root -m 0755 /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
if [[ -L /etc/nginx/conf.d/harbor-http.conf && $(readlink -- /etc/nginx/conf.d/harbor-http.conf) != /etc/harbor/nginx-http.conf ]]; then echo 'Unsafe Harbor NGINX HTTP include.' >&2; exit 1; fi
nginx_dump=$(nginx -T 2>&1)
if [[ ! -e /etc/nginx/conf.d/harbor-http.conf ]] && ! grep -Fq '# configuration file /etc/harbor/nginx-http.conf:' <<<"${nginx_dump}"; then
  ln -s /etc/harbor/nginx-http.conf /etc/nginx/conf.d/harbor-http.conf
fi
install -d -o root -g root -m 0755 /etc/letsencrypt/renewal-hooks/deploy
printf '#!/bin/sh\nexec /usr/local/lib/harbor/harbor-tls.py renew-deploy\n' >/etc/letsencrypt/renewal-hooks/deploy/harbor-nginx
chown root:root /etc/letsencrypt/renewal-hooks/deploy/harbor-nginx
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/harbor-nginx
install_progress 'Configure SSH, Fail2ban and website WAF'
"/usr/local/bin/harbor-package" install-ssh
"/usr/local/bin/harbor-package" install-cron
"/usr/local/bin/harbor-package" install-fail2ban
"/usr/local/bin/harbor-package" waf-install
install_progress 'Configure panel HTTPS and website challenge routes'
if [[ ${first_install} == 1 ]]; then
  /usr/local/lib/harbor/harbor-tls.py panel-setup "${server_fqdn}" "${panel_ip}"
fi
if ! /usr/local/lib/harbor/harbor-tls.py reconcile; then
  echo 'One or more existing website vhosts need a manual conflict review before Harbor can manage their HTTP challenge path.' >&2
fi
install_progress 'Start and enable core Harbor services'
systemctl enable --now harbor-web.socket harbor-dns.socket harbor-agent.service harbor-terminal.service harbor-web.service
systemctl try-restart harbor-agent.service harbor-web.service harbor-terminal.service harbor-dns.service harbor-filter.service harbor-signer.service
install_progress 'Validate and reload NGINX'
nginx -t
systemctl reload nginx.service
if [[ ${first_install} == 1 && -n ${acme_email} ]]; then
  issue_panel=${HARBOR_ISSUE_PANEL_CERT:-}
  if [[ -z ${issue_panel} && -t 0 ]]; then read -r -p "Request a Let's Encrypt certificate for ${server_fqdn} now? Public DNS and port 80 are required. [y/N]: " issue_panel; fi
  if [[ ${issue_panel} == y || ${issue_panel} == Y ]]; then
    if ! /usr/local/lib/harbor/harbor-tls.py issue-panel "${server_fqdn}"; then
      echo 'Certificate request failed. The panel remains available with its fallback certificate; review certbot output and public DNS/port 80.' >&2
    fi
  fi
fi
if [[ -f ${project_dir}/RELEASE.json ]]; then
  install -o root -g root -m 0644 "${project_dir}/RELEASE.json" /usr/local/share/harbor/release.json
else
  rm -f -- /usr/local/share/harbor/release.json
fi
echo 'Installed core packages. Fail2ban is enabled for panel login failures; the website WAF is in detection mode unless an existing mode was preserved.'
echo 'Panel origin and HTTPS vhost are configured. A browser will warn about the fallback certificate until a public certificate is issued.'
