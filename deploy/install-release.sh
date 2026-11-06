#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: bash deploy/install-release.sh RELEASE.tar.gz EXPECTED_SHA256' >&2; exit 2; }
[[ ${EUID} == 0 ]] || { echo 'Run this installer as root.' >&2; exit 1; }
[[ ! -e /etc/harbor/harbor.env && ! -e /var/lib/harbor/admins.json ]] || {
  echo 'An existing or partial Harbor installation was found. Review its state and installation log before retrying.' >&2; exit 1;
}
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'This release supports Ubuntu 24.04 LTS amd64 only.' >&2; exit 1;
}

umask 077
exec 9>/run/harbor-install.lock
flock -n 9 || { echo 'Another Harbor installation is already running.' >&2; exit 1; }
interactive=false
if [[ -t 0 && -t 1 ]]; then interactive=true; fi
[[ ! -L /var/log/harbor ]] || { echo 'Unsafe installation log directory.' >&2; exit 1; }
install -d -o root -g root -m 0700 /var/log/harbor
[[ $(stat -c '%u:%a' /var/log/harbor) == 0:700 ]] || { echo 'Unsafe installation log directory.' >&2; exit 1; }
install_log=$(mktemp "/var/log/harbor/install-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.log")
exec 3>&1
staging=
mutated=false
cancelled=false
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n ${staging} && ${staging} == /var/tmp/harbor-release.* ]]; then rm -rf -- "${staging}"; fi
  local outcome=completed
  if ${cancelled}; then outcome=cancelled; elif [[ ${status} != 0 ]]; then outcome=failed; fi
  printf '%s Installation %s (exit %s)\n' "$(date -u +%FT%TZ)" "${outcome}" "${status}" >>"${install_log}"
  if [[ ${status} != 0 ]]; then
    printf '\nInstallation stopped. Root-only log: %s\n' "${install_log}" >&2
    if ${mutated}; then printf 'A partial installation may exist. Inspect the failed stage before retrying.\n' >&2; fi
  fi
  exit "${status}"
}
trap cleanup EXIT
say() { printf '%s\n' "$*" >&3; }
prompt() {
  local name=$1 label=$2 default=$3 required=$4 answer=
  if [[ -n ${!name:-} ]]; then return; fi
  if ! ${interactive}; then
    if [[ ${required} == yes && -z ${default} ]]; then echo "Set ${name} for unattended installation." >&2; return 1; fi
    printf -v "${name}" '%s' "${default}"
    return
  fi
  read -r -p "${label}${default:+ [${default}]}: " answer
  printf -v "${name}" '%s' "${answer:-$default}"
}
validate_settings() {
  python3 - "${HARBOR_SERVER_FQDN}" "${HARBOR_PANEL_IP}" "${HARBOR_ACME_EMAIL}" \
    "${HARBOR_ADMIN_AUTH_MODE}" "${HARBOR_INITIAL_ADMIN_USER}" "${HARBOR_ISSUE_PANEL_CERT}" <<'PY'
import ipaddress,re,sys
host,ip,email,mode,admin,issue=sys.argv[1:]
if len(host)>253 or not re.fullmatch(r'[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9]+(?:[a-z0-9-]*[a-z0-9])?)+',host) or any(len(part)>63 for part in host.split('.')):
    sys.exit('Panel FQDN must be a lowercase, complete DNS hostname.')
try: ipaddress.IPv4Address(ip)
except ValueError: sys.exit('Fallback address must be one IPv4 address.')
if email and not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+',email): sys.exit('Invalid certificate contact email.')
if mode not in ('token','password'): sys.exit('Administrator login mode must be token or password.')
if not re.fullmatch(r'[a-z][a-z0-9_-]{2,31}',admin): sys.exit('Administrator name must be 3–32 lowercase letters, digits, underscores or hyphens.')
if issue not in ('y','n'): sys.exit('Certificate choice must be y or n.')
if issue=='y' and not email: sys.exit('A contact email is required to request a certificate now.')
PY
}
step=0
run_step() {
  local label=$1 status
  shift
  step=$((step+1))
  say "[${step}/9] ${label}..."
  printf '%s [%s/9] %s\n' "$(date -u +%FT%TZ)" "${step}" "${label}" >>"${install_log}"
  if "$@" >>"${install_log}" 2>&1; then
    say '    Done.'
  else
    status=$?
    say "    Failed. See ${install_log}"
    return "${status}"
  fi
}

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
say 'Harbor guided installation · Ubuntu 24.04 amd64'
say "Root-only installation log: ${install_log}"
run_step 'Verify release checksum and manifest' bash "${script_dir}/update.sh" --verify-only "$1" "$2"

detected_ip=$(hostname -I 2>/dev/null | python3 -c 'import ipaddress,sys; print(next((v for v in sys.stdin.read().split() if v.count(".")==3 and ipaddress.ip_address(v).version==4),""))')
say ''
say 'Panel and administrator settings'
prompt HARBOR_SERVER_FQDN 'Panel FQDN' '' yes
prompt HARBOR_PANEL_IP 'Fallback IPv4 address' "${detected_ip}" yes
prompt HARBOR_ACME_EMAIL "Let's Encrypt contact email (optional)" '' no
prompt HARBOR_ADMIN_AUTH_MODE 'Super admin login mode: token or password' token yes
prompt HARBOR_INITIAL_ADMIN_USER 'Super admin username' admin yes
if [[ -z ${HARBOR_ISSUE_PANEL_CERT:-} ]]; then
  if ${interactive}; then say 'A trusted certificate now requires public DNS pointing here and inbound port 80.'; fi
  prompt HARBOR_ISSUE_PANEL_CERT 'Request a trusted panel certificate now? y/n' n yes
fi
validate_settings
export HARBOR_SERVER_FQDN HARBOR_PANEL_IP HARBOR_ACME_EMAIL HARBOR_ADMIN_AUTH_MODE HARBOR_INITIAL_ADMIN_USER HARBOR_ISSUE_PANEL_CERT
say ''
say "Panel: https://${HARBOR_SERVER_FQDN}/"
say "IP fallback: https://${HARBOR_PANEL_IP}/"
say "Super admin: ${HARBOR_INITIAL_ADMIN_USER} (${HARBOR_ADMIN_AUTH_MODE})"
say "Certificate request now: ${HARBOR_ISSUE_PANEL_CERT}"
if ${interactive}; then
  read -r -p 'Install Harbor with these settings? [y/N]: ' confirm
  [[ ${confirm} == y || ${confirm} == Y ]] || { cancelled=true; say 'Installation cancelled before package changes.'; exit 0; }
fi
printf '%s Panel=%s IP=%s Admin=%s Mode=%s IssueCert=%s\n' "$(date -u +%FT%TZ)" \
  "${HARBOR_SERVER_FQDN}" "${HARBOR_PANEL_IP}" "${HARBOR_INITIAL_ADMIN_USER}" \
  "${HARBOR_ADMIN_AUTH_MODE}" "${HARBOR_ISSUE_PANEL_CERT}" >>"${install_log}"

staging=$(mktemp -d /var/tmp/harbor-release.XXXXXXXX)
extract_release() { release_dir=$(python3 "${script_dir}/release_bundle.py" extract "$1" "${staging}"); }
run_step 'Extract verified runtime files' extract_release "$1"
release_tag=$(python3 - "${release_dir}/RELEASE.json" <<'PY'
import json,sys
print(json.load(open(sys.argv[1],encoding='utf-8'))['tag'])
PY
)
mutated=true
run_step 'Refresh Ubuntu package lists' apt-get update
run_step 'Install bootstrap packages' env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  software-properties-common ca-certificates openssl python3 passwd util-linux curl
run_step 'Enable Ubuntu universe packages' add-apt-repository -y universe
run_step 'Refresh enabled package lists' apt-get update
# The compiled executables are installed directly; no compiler runs on the host.
run_step 'Install native runtime libraries' env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  libsystemd-dev libcpp-httplib-dev nlohmann-json3-dev libssl-dev libpam0g-dev \
  libmariadb-dev libpq-dev libcrypt-dev libopendkim-dev libmilter-dev libxml2-dev
export HARBOR_INSTALL_PROGRESS_FD=3
run_step 'Configure Harbor, security and core services' bash "${release_dir}/deploy/install.sh"
unset HARBOR_INSTALL_PROGRESS_FD

smoke_test() {
  local unit
  for unit in nginx.service harbor-agent.service harbor-terminal.service harbor-web.socket harbor-web.service harbor-dns.socket; do
    systemctl is-active --quiet "${unit}" || { echo "Inactive service: ${unit}" >&2; return 1; }
  done
  local fallback=/etc/harbor/self-signed/panel.crt
  curl --noproxy '*' --fail --silent --show-error --max-time 10 --cacert "${fallback}" \
    -o /dev/null "https://${HARBOR_PANEL_IP}/"
  if [[ -f /etc/letsencrypt/live/${HARBOR_SERVER_FQDN}/fullchain.pem ]]; then
    curl --noproxy '*' --fail --silent --show-error --max-time 10 \
      --resolve "${HARBOR_SERVER_FQDN}:443:${HARBOR_PANEL_IP}" -o /dev/null "https://${HARBOR_SERVER_FQDN}/"
  else
    curl --noproxy '*' --fail --silent --show-error --max-time 10 --cacert "${fallback}" \
      --resolve "${HARBOR_SERVER_FQDN}:443:${HARBOR_PANEL_IP}" -o /dev/null "https://${HARBOR_SERVER_FQDN}/"
  fi
}
run_step 'Verify services and HTTPS panel routes' smoke_test

credential_file=/etc/harbor/initial-admin-${HARBOR_ADMIN_AUTH_MODE}
[[ -f ${credential_file} && ! -L ${credential_file} && $(stat -c '%u:%a' "${credential_file}") == 0:600 ]] || {
  echo 'Initial administrator credential file is missing or unsafe.' >&2
  exit 1
}
say ''
say 'Harbor installation completed.'
say "Release: ${release_tag} · Ubuntu 24.04 amd64"
say "Panel: https://${HARBOR_SERVER_FQDN}/"
say "IP fallback: https://${HARBOR_PANEL_IP}/ (local certificate)"
if [[ -f /etc/letsencrypt/live/${HARBOR_SERVER_FQDN}/fullchain.pem ]]; then
  say 'Panel certificate: trusted certificate installed'
else
  say 'Panel certificate: local fallback; request a trusted certificate after public DNS and port 80 are ready'
  say "Next: point ${HARBOR_SERVER_FQDN} to ${HARBOR_PANEL_IP}, then request the panel certificate."
fi
say "Super admin: ${HARBOR_INITIAL_ADMIN_USER} (${HARBOR_ADMIN_AUTH_MODE})"
if ${interactive}; then
  IFS= read -r credential <"${credential_file}"
  if [[ ${HARBOR_ADMIN_AUTH_MODE} == token ]]; then say "Admin token: ${credential}"; else say "Initial password: ${credential}"; fi
  unset credential
  say 'Store this credential securely, then remove its root-only file when no longer needed.'
else
  say "Initial credential: ${credential_file} (root only; not printed without an interactive terminal)"
fi
say "Installation log: ${install_log} (root only; credential omitted)"
