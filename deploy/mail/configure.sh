#!/usr/bin/env bash
# Configure a dedicated Ubuntu 24.04 mail host after reviewing the templates.
set -euo pipefail
if [[ ${EUID} -ne 0 || $# -ne 4 || $1 != --replace-mail-config ]]; then
  echo 'Usage: sudo bash deploy/mail/configure.sh --replace-mail-config mail.example.com /absolute/fullchain.pem /absolute/privkey.pem' >&2
  echo 'Replaces Postfix and Dovecot configuration, retaining a root-only backup. Existing mail setups must be migrated separately.' >&2; exit 1
fi
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 ]] || { echo 'Ubuntu 24.04 is required.' >&2; exit 1; }
mail_hostname=$2; certificate=$3; private_key=$4
[[ ${mail_hostname} =~ ^[a-z0-9][a-z0-9.-]+\.[a-z]+$ && ${mail_hostname} != *..* ]] || { echo 'Invalid mail hostname.' >&2; exit 1; }
[[ ${#mail_hostname} -le 253 ]] || { echo 'Mail hostname is too long.' >&2; exit 1; }
IFS='.' read -r -a mail_labels <<<"${mail_hostname}"
for mail_label in "${mail_labels[@]}"; do
  [[ ${#mail_label} -le 63 && ${mail_label} =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || { echo 'Invalid mail hostname label.' >&2; exit 1; }
done
for path in "${certificate}" "${private_key}"; do
  [[ ${path} =~ ^/[A-Za-z0-9_./-]+$ && -f ${path} ]] || { echo 'Use existing absolute certificate/key paths without special characters.' >&2; exit 1; }
done
for executable in /usr/sbin/postfix /usr/sbin/postconf /usr/bin/doveconf /usr/bin/doveadm; do
  [[ -x ${executable} ]] || { echo 'Install postfix, dovecot-core, dovecot-imapd and dovecot-lmtpd first.' >&2; exit 1; }
done
[[ $(/usr/sbin/dovecot --version) == 2.3.* ]] || { echo 'Dovecot 2.3 is required.' >&2; exit 1; }
[[ -x /usr/local/bin/harbor-filter && -f /etc/harbor/mail/harbor.svbin && -x /usr/local/bin/harbor-signer && -x /usr/local/bin/harbor-agent ]] && getent group harbor-signer >/dev/null || { echo 'Install the updated Harbor core first.' >&2; exit 1; }
template_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! getent passwd harbor-vmail >/dev/null; then
  useradd --system --user-group --home-dir /var/lib/harbor-mail --shell /usr/sbin/nologin harbor-vmail
fi
[[ $(id -u harbor-vmail) -ne 0 && $(getent passwd harbor-vmail | cut -d: -f7) == /usr/sbin/nologin && $(getent passwd harbor-vmail | cut -d: -f6) == /var/lib/harbor-mail ]] || { echo 'Unsuitable existing virtual mail identity.' >&2; exit 1; }
backup_dir=$(mktemp -d /var/backups/harbor-mail-XXXXXXXX)
install -d -m 0700 "${backup_dir}"
cp -a -- /etc/postfix/main.cf /etc/postfix/master.cf /etc/dovecot/dovecot.conf "${backup_dir}/"
if [[ -f /etc/harbor/mail/server.json ]]; then cp -a -- /etc/harbor/mail/server.json "${backup_dir}/server.json"; fi
install -d -o harbor-vmail -g harbor-vmail -m 0700 /var/lib/harbor-mail
install -d -o root -g root -m 0755 /etc/harbor/mail
if [[ ! -e /etc/harbor/mail/current ]]; then
  install -d -o root -g root -m 0755 /etc/harbor/mail/generation-initial
  for map in domains recipients senders aliases; do install -o root -g postfix -m 0640 /dev/null "/etc/harbor/mail/generation-initial/${map}"; done
  install -o root -g dovecot -m 0640 /dev/null /etc/harbor/mail/generation-initial/passwd
  ln -s generation-initial /etc/harbor/mail/current
fi
if [[ ! -f /etc/harbor/mail/current/signing.json ]]; then
  printf '{"senders":{},"domains":{}}\n' >/etc/harbor/mail/current/signing.json
  chown root:harbor-signer /etc/harbor/mail/current/signing.json
  chmod 0640 /etc/harbor/mail/current/signing.json
fi
if [[ ! -f /etc/harbor/mail/current/discovery.json ]]; then
  printf '{"hostname":"","domains":{}}\n' >/etc/harbor/mail/current/discovery.json
  chown root:root /etc/harbor/mail/current/discovery.json
  chmod 0644 /etc/harbor/mail/current/discovery.json
fi
if [[ ! -f /etc/harbor/mail/current/aliases ]]; then install -o root -g postfix -m 0640 /dev/null /etc/harbor/mail/current/aliases; fi
if [[ ! -f /etc/harbor/mail/current/filter.json ]]; then
  printf '{"junkScore":5,"rejectScore":15,"blocked":[],"recipients":{}}\n' >/etc/harbor/mail/current/filter.json
  chown root:harbor-filter /etc/harbor/mail/current/filter.json; chmod 0640 /etc/harbor/mail/current/filter.json
fi
printf '{"hostname":"%s"}\n'  "${mail_hostname}" >/etc/harbor/mail/server.json
chown root:root /etc/harbor/mail/server.json
chmod 0644 /etc/harbor/mail/server.json
render() {
  sed -e "s|@HOSTNAME@|${mail_hostname}|g" -e "s|@CERTIFICATE@|${certificate}|g" -e "s|@PRIVATE_KEY@|${private_key}|g" -e "s|@VMAIL_UID@|$(id -u harbor-vmail)|g" "$1" >"$2"
  chown root:root "$2"; chmod 0644 "$2"
}
render "${template_dir}/main.cf.example" /etc/postfix/main.cf
render "${template_dir}/master.cf.example" /etc/postfix/master.cf
render "${template_dir}/dovecot.conf.example" /etc/dovecot/dovecot.conf
if ! postfix check || ! doveconf -n >/dev/null; then
  cp -a -- "${backup_dir}/main.cf" /etc/postfix/main.cf
  cp -a -- "${backup_dir}/master.cf" /etc/postfix/master.cf
  cp -a -- "${backup_dir}/dovecot.conf" /etc/dovecot/dovecot.conf
  if [[ -f ${backup_dir}/server.json ]]; then cp -a -- "${backup_dir}/server.json" /etc/harbor/mail/server.json; else rm -f -- /etc/harbor/mail/server.json; fi
  echo 'Validation failed. Original configuration restored; inspect certificate permissions and package state.' >&2; exit 1
fi
# Enablement is explicit here because the operator invoked --replace-mail-config.
systemctl enable --now rspamd harbor-filter harbor-signer
systemctl enable --now postfix dovecot
systemctl reload postfix dovecot
install -o root -g root -m 0600 /dev/null /etc/harbor/mail/ready
/usr/local/bin/harbor-agent --render-mail
echo "Mail configuration loaded. Backup: ${backup_dir}. Owners can now opt in. Review https://github.com/patriumgroup/Harbor/blob/main/docs/HOSTING.md before publishing mail DNS."
