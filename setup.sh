#!/usr/bin/env bash
# Public entry point for Harbor installation and console upgrades.
set -euo pipefail
umask 077

verify_only=false
upgrade=false
for option in "$@"; do
  case ${option} in
    --verify-only) verify_only=true ;;
    --upgrade) upgrade=true ;;
    *) echo 'Usage: bash setup.sh [--upgrade] [--verify-only]' >&2; exit 2 ;;
  esac
done
[[ ${EUID} == 0 ]] || { echo 'Run Harbor setup as root.' >&2; exit 1; }
if ! ${verify_only}; then
  [[ -t 0 && -t 1 ]] || { echo 'Run Harbor setup in an interactive terminal.' >&2; exit 1; }
fi
if ${upgrade}; then
  [[ -f /etc/harbor/harbor.env && ! -L /etc/harbor/harbor.env &&
     -f /var/lib/harbor/admins.json && ! -L /var/lib/harbor/admins.json ]] || {
    echo 'No complete Harbor installation was found. Use setup without --upgrade for a fresh host.' >&2; exit 1;
  }
else
  [[ ! -e /etc/harbor/harbor.env && ! -e /var/lib/harbor/admins.json ]] || {
    echo 'An existing or partial Harbor installation was found. Use --upgrade only for a complete installation.' >&2; exit 1;
  }
fi
source /etc/os-release
[[ ${ID} == ubuntu && ( ${VERSION_ID} == 26.04 || ${VERSION_ID} == 24.04 ) && $(dpkg --print-architecture) == amd64 ]] || {
  echo 'Harbor setup supports Ubuntu 26.04 LTS amd64 and legacy Ubuntu 24.04 amd64 hosts.' >&2; exit 1;
}
platform="ubuntu${VERSION_ID}-amd64"

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
exec 9>/run/harbor-setup.lock
flock -n 9 || { echo 'Another Harbor setup is running.' >&2; exit 1; }
[[ ! -L /var/log/harbor ]] || { echo 'Unsafe setup log directory.' >&2; exit 1; }
install -d -o root -g root -m 0700 /var/log/harbor
[[ $(stat -c '%u:%a' /var/log/harbor) == 0:700 ]] || { echo 'Unsafe setup log directory.' >&2; exit 1; }
log_type=setup
if ${upgrade}; then log_type=upgrade; fi
setup_log=$(mktemp "/var/log/harbor/${log_type}-$(date -u +%Y%m%dT%H%M%SZ).XXXXXX.log")
workdir=$(mktemp -d /var/tmp/harbor-setup.XXXXXXXX)
cleanup() {
  local status=$?
  trap - EXIT
  if [[ ${workdir} == /var/tmp/harbor-setup.* ]]; then rm -rf -- "${workdir}" || true; fi
  if ${upgrade}; then
    printf '%s Upgrade exit status: %s\n' "$(date -u +%FT%TZ)" "${status}" >>"${setup_log}"
  else
    printf '%s Setup exit status: %s\n' "$(date -u +%FT%TZ)" "${status}" >>"${setup_log}"
  fi
  if [[ ${status} != 0 ]]; then printf '%s stopped. Root-only log: %s\n' "${log_type}" "${setup_log}" >&2; fi
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
  python3 - releases.json "${platform}" <<'PY'
import json,re,sys
with open(sys.argv[1],encoding='utf-8') as stream:
    releases=json.load(stream)
platform=sys.argv[2]
if not isinstance(releases,list):
    raise SystemExit('Unexpected public release response')
for release in sorted(releases,key=lambda item:item.get('published_at') or '',reverse=True):
    tag=release.get('tag_name','')
    if release.get('draft') or not re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?',tag):
        continue
    archive=f'harbor-{tag}-{platform}.tar.gz'
    assets={asset.get('name'):asset for asset in release.get('assets',[])}
    required=(archive,archive+'.sha256')
    if all(name in assets and assets[name].get('size',0)>0 and assets[name].get('state')=='uploaded' and
           re.fullmatch(r'sha256:[0-9a-f]{64}',assets[name].get('digest','')) for name in required):
        print(tag,assets[archive]['digest'][7:],assets[archive+'.sha256']['digest'][7:])
        break
else:
    raise SystemExit(f'No complete {platform} public release is available')
PY
}
select_release_from_channel() {
  python3 - channel.json "${platform}" <<'PY'
import json,re,sys
with open(sys.argv[1],encoding='utf-8') as stream:
    channel=json.load(stream)
platform=sys.argv[2]
if not isinstance(channel,dict):
    raise SystemExit('Invalid public release channel')
if channel.get('version')==2:
    channel=channel.get('platforms',{}).get(platform,{})
elif channel.get('version')==1 and platform=='ubuntu24.04-amd64':
    pass
else:
    raise SystemExit('No channel entry for this Ubuntu platform')
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
  archive="harbor-${release_tag}-${platform}.tar.gz"
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
  python3 - "${archive}" "${release_tag}" "${platform}" <<'PY'
import pathlib,sys,tarfile
archive,tag,platform=sys.argv[1:]
root=f'harbor-{tag}-{platform}'
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
  release_dir="${workdir}/harbor-${release_tag}-${platform}"
  python3 "${release_dir}/deploy/release_bundle.py" verify "${archive}" || return
  bash -n "${release_dir}/deploy/install-release.sh"
}

echo "Harbor setup · ${platform}"
if ${upgrade}; then echo 'Console upgrade mode'; fi
echo "Root-only setup log: ${setup_log}"
stage 'Refresh Ubuntu package lists' apt-get update
stage 'Install download and verification tools' apt-get install -y --no-install-recommends ca-certificates curl python3
stage 'Find the newest complete public release' fetch_release_metadata
stage 'Select the Ubuntu release' select_release
stage 'Download release archive and checksum' download_release
stage 'Verify and unpack the release' verify_and_extract
if ${verify_only}; then
  printf 'Verified public release %s. Log: %s\n' "${release_tag}" "${setup_log}"
  exit 0
fi

step=7
if ${upgrade}; then
  version_result=$(python3 - "${release_tag}" <<'PY'
import json,os,pathlib,re,stat,sys
path=pathlib.Path('/usr/local/share/harbor/release.json')
try:
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
except FileNotFoundError:
    print('unknown')
    sys.exit(0)
try:
    info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=0 or info.st_nlink!=1 or info.st_mode & 0o022 or info.st_size>4096:
        raise SystemExit('Unsafe installed release metadata')
    current=json.loads(os.read(fd,4097)).get('tag','')
finally:
    os.close(fd)
pattern=r'v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)\.(\d+))?'
def version(value):
    match=re.fullmatch(pattern,value)
    if not match:return None
    major,minor,patch,stage,number=match.groups()
    return int(major),int(minor),int(patch),{'alpha':0,'beta':1,None:2}[stage],int(number or 0)
installed=version(current)
selected=version(sys.argv[1])
if selected is None:raise SystemExit('Invalid selected release tag')
print('unknown' if installed is None else 'same' if installed==selected else 'older' if installed>selected else 'newer')
PY
  )
  case ${version_result} in
    same) printf 'Harbor %s is already installed.\n' "${release_tag}"; exit 0 ;;
    older) printf 'Installed Harbor is newer than %s; refusing to downgrade.\n' "${release_tag}" >&2; exit 1 ;;
    unknown|newer) ;;
    *) printf 'Cannot compare installed Harbor version.\n' >&2; exit 1 ;;
  esac
  printf '[7/7] Back up and upgrade Harbor to %s...\n' "${release_tag}"
  printf '%s [7/7] Back up and upgrade Harbor to %s\n' "$(date -u +%FT%TZ)" "${release_tag}" >>"${setup_log}"
  if bash "${release_dir}/deploy/update.sh" "${archive}" "${digest}" >>"${setup_log}" 2>&1; then
    printf 'Harbor upgraded to %s. Root-only log: %s\n' "${release_tag}" "${setup_log}"
  else
    printf 'Upgrade failed. Review %s and the backup path recorded there.\n' "${setup_log}" >&2
    exit 1
  fi
else
  printf '[7/7] Start guided Harbor installation...\n'
  printf '%s [7/7] Start guided Harbor installation\n' "$(date -u +%FT%TZ)" >>"${setup_log}"
  export HARBOR_BOOTSTRAP_LOG="${setup_log}"
  bash "${release_dir}/deploy/install-release.sh" "${archive}" "${digest}"
fi
