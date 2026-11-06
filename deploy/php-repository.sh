#!/usr/bin/env bash
set -euo pipefail
[[ ${EUID} -eq 0 ]] || { echo 'Root required for PHP repository setup.' >&2; exit 1; }
source /etc/os-release
[[ ${ID} == ubuntu && ${VERSION_ID} == 24.04 ]] || { echo 'PHP repository setup supports Ubuntu 24.04 only.' >&2; exit 1; }
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install -o root -g root -m 0644 "${script_dir}/php-ppa.pref" /etc/apt/preferences.d/harbor-php-ppa.pref
apt-get update
apt-get install -y --no-install-recommends software-properties-common
if ! grep -Rqs 'ppa.launchpadcontent.net/ondrej/php/ubuntu' /etc/apt/sources.list.d; then
  add-apt-repository -y ppa:ondrej/php
fi
apt-get update
echo 'The optional signed PHP PPA is configured. Ubuntu packages retain priority for PHP 8.3.'
