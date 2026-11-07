#!/usr/bin/env bash
# Public entry point for a fresh Harbor installation.
set -euo pipefail
umask 077

verify_only=false
if [[ $# == 1 && $1 == --verify-only ]]; then
  verify_only=true
elif [[ $# != 0 ]]; then
  echo 'Usage: bash setup.sh [--verify-only]' >&2
  exit 2
fi
[[ ${EUID} == 0 ]] || { echo 'Run Harbor setup as root.' >&2; exit 1; }
if ! ${verify_only}; then
  [[ -t 0 && -t 1 ]] || { echo 'Run Harbor setup in an interactive terminal.' >&2; exit 1; }
fi
[[ ! -e /etc/harbor/harbor.env && ! -e /var/lib/harbor/admins.json ]] || {
  echo 'An existing or partial Harbor installation was found. Review its log before retrying.' >&2; exit 1;
}
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'Harbor setup supports Ubuntu 24.04 LTS amd64 only.' >&2; exit 1;
}

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
exec 9>/run/harbor-setup.lock
flock -n 9 || { echo 'Another Harbor setup is running.' >&2; exit 1; }
[[ ! -L /var/log/harbor ]] || { echo 'Unsafe setup log directory.' >&2; exit 1; }
install -d -o root -g root -m 0700 /var/log/harbor
[[ $(stat -c '%u:%a' /var/log/harbor) == 0:700 ]] || { echo 'Unsafe setup log directory.' >&2; exit 1; }
setup_log=$(mktemp "/var/log/harbor/setup-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.log")
workdir=$(mktemp -d /var/tmp/harbor-setup.XXXXXXXX)
cleanup() {
  local status=$?
  trap - EXIT
  if [[ ${workdir} == /var/tmp/harbor-setup.* ]]; then rm -rf -- "${workdir}" || true; fi
  printf '%s Setup exit status: %s\n' "$(date -u +%FT%TZ)" "${status}" >>"${setup_log}"
  if [[ ${status} != 0 ]]; then printf 'Setup stopped. Root-only log: %s\n' "${setup_log}" >&2; fi
  exit "${status}"
}
trap cleanup EXIT
cd -- "${workdir}"

step=0
stage() {
  local label=$1 status
  shift
  step=$((step+1))
  printf '[%s/7] %s...\n' "${step}" "${label}"
  printf '%s [%s/7] %s\n' "$(date -u +%FT%TZ)" "${step}" "${label}" >>"${setup_log}"
  if "$@" >>"${setup_log}" 2>&1; then
    echo '    Done.'
  else
    status=$?
    printf '    Failed. See %s\n' "${setup_log}" >&2
    return "${status}"
  fi
}

fetch() {
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 180 \
    --proto '=https' --proto-redir '=https' \
    -H 'User-Agent: Harbor-Setup' "$1" -o "$2"
}
fetch_release_metadata() {
  if [[ ${HARBOR_SETUP_CHANNEL_ONLY:-0} != 1 ]] &&
     fetch 'https://api.github.com/repos/patriumgroup/Harbor-Downloads/releases?per_page=30' releases.json; then return; fi
  if [[ ${HARBOR_SETUP_CHANNEL_ONLY:-0} == 1 ]]; then
    echo 'Using the public channel manifest for this verification.' >&2
  else
    echo 'GitHub release API unavailable; using the public channel manifest.' >&2
  fi
  fetch 'https://raw.githubusercontent.com/patriumgroup/Harbor-Downloads/main/channel.json' channel.json
}
select_release_from_api() {
  python3 - releases.json <<'PY'
import json,re,sys
with open(sys.argv[1],encoding='utf-8') as stream:
    releases=json.load(stream)
if not isinstance(releases,list):
    raise SystemExit('Unexpected public release response')
for release in sorted(releases,key=lambda item:item.get('published_at') or '',reverse=True):
    tag=release.get('tag_name','')
    if release.get('draft') or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?',tag):
        continue
    archive=f'harbor-{tag}-ubuntu24.04-amd64.tar.gz'
    assets={asset.get('name'):asset for asset in release.get('assets',[])}
    required=(archive,archive+'.sha256')
    if all(name in assets and assets[name].get('size',0)>0 and assets[name].get('state')=='uploaded' and
           re.fullmatch(r'sha256:[0-9a-f]{64}',assets[name].get('digest','')) for name in required):
        print(tag,assets[archive]['digest'][7:],assets[archive+'.sha256']['digest'][7:])
        break
else:
    raise SystemExit('No complete Ubuntu 24.04 amd64 public release is available')
PY
}
select_release_from_channel() {
  python3 - channel.json <<'PY'
import json,re,sys
with open(sys.argv[1],encoding='utf-8') as stream:
    channel=json.load(stream)
if not isinstance(channel,dict) or channel.get('version')!=1:
    raise SystemExit('Invalid public release channel')
tag=channel.get('tag','')
archive=channel.get('archiveSha256','')
checksum=channel.get('checksumSha256','')
if (not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?',tag) or
    not re.fullmatch(r'[0-9a-f]{64}',archive) or not re.fullmatch(r'[0-9a-f]{64}',checksum)):
    raise SystemExit('Invalid public release channel')
print(tag,archive,checksum)
PY
}
select_release() {
  local selection=''
  if [[ -f releases.json ]]; then selection=$(select_release_from_api) || selection=''; fi
  if [[ -z ${selection} ]]; then
    echo 'Using the public channel manifest for release selection.' >&2
    [[ -f channel.json ]] || fetch 'https://raw.githubusercontent.com/patriumgroup/Harbor-Downloads/main/channel.json' channel.json || return
    selection=$(select_release_from_channel) || return
  fi
  read -r release_tag asset_archive_digest asset_checksum_digest <<<"${selection}"
  printf 'Selected %s\n' "${release_tag}"
}
download_release() {
  archive="harbor-${release_tag}-ubuntu24.04-amd64.tar.gz"
  local base="https://github.com/patriumgroup/Harbor-Downloads/releases/download/${release_tag}"
  fetch "${base}/${archive}" "${archive}" || return
  fetch "${base}/${archive}.sha256" "${archive}.sha256"
}
verify_and_extract() {
  digest=$(python3 - "${archive}.sha256" "${archive}" <<'PY'
import pathlib,re,sys
lines=pathlib.Path(sys.argv[1]).read_text(encoding='ascii').splitlines()
match=re.fullmatch(r'([0-9a-f]{64})  '+re.escape(sys.argv[2]),lines[0]) if len(lines)==1 else None
if not match:
    raise SystemExit('Unexpected release checksum file')
print(match.group(1))
PY
  ) || return
  local actual_archive actual_checksum
  actual_archive=$(sha256sum -- "${archive}") || return
  actual_checksum=$(sha256sum -- "${archive}.sha256") || return
  [[ ${actual_archive%% *} == "${digest}" && ${actual_archive%% *} == "${asset_archive_digest}" &&
     ${actual_checksum%% *} == "${asset_checksum_digest}" ]] || {
    echo 'Downloaded assets do not match the release metadata and checksum.' >&2; return 1;
  }
  python3 - "${archive}" "${release_tag}" <<'PY'
import pathlib,sys,tarfile
archive,tag=sys.argv[1:]
root=f'harbor-{tag}-ubuntu24.04-amd64'
with tarfile.open(archive,'r:gz') as bundle:
    members=bundle.getmembers()
    if not members or len(members)>512 or sum(item.size for item in members)>100*1024*1024:
        raise SystemExit('Release archive is empty or too large')
    seen=set()
    for item in members:
        parts=pathlib.PurePosixPath(item.name).parts
        if not item.isfile() or len(parts)<2 or parts[0]!=root or '..' in parts or item.name!=str(pathlib.PurePosixPath(item.name)) or item.name in seen:
            raise SystemExit('Unsafe release archive entry')
        seen.add(item.name)
    bundle.extractall('.',filter='data')
PY
  [[ $? == 0 ]] || return
  release_dir="${workdir}/harbor-${release_tag}-ubuntu24.04-amd64"
  python3 "${release_dir}/deploy/release_bundle.py" verify "${archive}" || return
  bash -n "${release_dir}/deploy/install-release.sh"
}

echo 'Harbor setup · Ubuntu 24.04 amd64'
echo "Root-only setup log: ${setup_log}"
stage 'Refresh Ubuntu package lists' apt-get update
stage 'Install download and verification tools' apt-get install -y --no-install-recommends ca-certificates curl python3
stage 'Find the newest complete public release' fetch_release_metadata
stage 'Select the Ubuntu release' select_release
stage 'Download release archive and checksum' download_release
stage 'Verify and unpack the release' verify_and_extract
if ${verify_only}; then
  printf 'Verified public release %s. Setup log: %s\n' "${release_tag}" "${setup_log}"
  exit 0
fi

step=7
printf '[7/7] Start guided Harbor installation...\n'
printf '%s [7/7] Start guided Harbor installation\n' "$(date -u +%FT%TZ)" >>"${setup_log}"
export HARBOR_BOOTSTRAP_LOG="${setup_log}"
bash "${release_dir}/deploy/install-release.sh" "${archive}" "${digest}"
