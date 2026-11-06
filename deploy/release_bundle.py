#!/usr/bin/env python3
"""Build and verify a Harbor runtime-only release archive."""

import argparse
import gzip
import hashlib
import io
import json
import pathlib
import re
import subprocess
import sys
import tarfile


BINARIES = (
    "harbor-agent", "harbor-web", "harbor-terminal", "harbor-dns",
    "harbor-signer", "harbor-filter", "harborctl", "harbor-package",
)
# Explicit payload inventory. New files do not enter a release by directory
# convention; the runtime allowlist must be reviewed when they are added.
RUNTIME_PATHS = set("""
deploy/database-tools/admin-phpmyadmin-pool.conf
deploy/database-tools/config_local.py
deploy/database-tools/harbor_pgadmin.py
deploy/database-tools/harbor-admin-pgadmin.service
deploy/database-tools/harbor-admin-pgadmin.socket
deploy/database-tools/harbor-pgadmin.service
deploy/database-tools/harbor-pgadmin.socket
deploy/database-tools/nginx-locations.conf.example
deploy/database-tools/pg_sso.py
deploy/database-tools/phpmyadmin-pool.conf
deploy/database-tools/phpmyadmin.php
deploy/database-tools/requirements.txt
deploy/database-tools/setup.sh
deploy/database-tools/signon.php
deploy/database-tools/sso-client.php
deploy/harbor-agent.service
deploy/harbor-cert@.service
deploy/harbor-dns.service
deploy/harbor-dns.socket
deploy/harbor-filter.service
deploy/harbor-package@.service
deploy/harbor-release-auto.timer
deploy/harbor-release@.service
deploy/harbor-signer.service
deploy/harbor-terminal.service
deploy/harbor-web.service
deploy/harbor-web.socket
deploy/harbor.pam
deploy/harbor-tls.py
deploy/install-release.sh
deploy/install.sh
deploy/mail/configure.sh
deploy/mail/dovecot.conf.example
deploy/mail/main.cf.example
deploy/mail/master.cf.example
deploy/mail/nginx-discovery.conf.example
deploy/mail/spam/harbor-spam-redis.service
deploy/mail/spam/harbor.sieve
deploy/mail/spam/redis.conf
deploy/mail/spam/setup.sh
deploy/nginx.conf.example
deploy/php-ppa.pref
deploy/php-repository.sh
deploy/release_bundle.py
deploy/release_manager.py
deploy/security/harbor-basic.conf
deploy/security/harbor-http.conf
deploy/security/harbor-modsecurity.conf
deploy/security/harbor-panel.conf
deploy/security/harbor-panel.logrotate
deploy/security/harbor-sites.logrotate
deploy/security/harbor.local
deploy/security/nginx-waf-test.conf
deploy/uninstall.sh
deploy/update.sh
deploy/webmail/config.inc.php
deploy/webmail/harbor_sso.php
deploy/webmail/nginx-locations.conf.example
deploy/webmail/setup.sh
web/admins.js
web/app.js
web/index.html
web/mark.svg
web/panel-views.js
web/styles.css
web/updates.js
web/vendor/XTERM-LICENSE.txt
web/vendor/xterm.css
web/vendor/xterm.js
""".split())
RUNTIME_REQUIRED = RUNTIME_PATHS | {"RELEASE.json", "LICENSE", "THIRD_PARTY_NOTICES.txt"}
FORBIDDEN_NAMES = {"admins.json", "credentials.json", "initial-admin-token", "initial-admin-password"}
FORBIDDEN_SUFFIXES = {".env", ".key", ".pem", ".p12", ".pfx", ".sqlite", ".db", ".log", ".pyc"}
SECRET_PATTERN = re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----|(?:ghp_|gho_|ghu_|github_pat_)[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}")
MAX_MEMBERS = 512
MAX_FILE_SIZE = 20 * 1024 * 1024
MAX_TOTAL_SIZE = 100 * 1024 * 1024
ROOT_PATTERN = re.compile(r"harbor-v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?-ubuntu24\.04-amd64")
TAG_PATTERN = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?")


def digest(stream):
    result = hashlib.sha256()
    while chunk := stream.read(1024 * 1024):
        result.update(chunk)
    return result.hexdigest()


def create(tag, output):
    if not TAG_PATTERN.fullmatch(tag):
        raise ValueError("Use a stable, alpha, or beta version tag")
    project = pathlib.Path(__file__).resolve().parents[1]
    root = f"harbor-{tag}-ubuntu24.04-amd64"
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f"{root}.tar.gz"
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=project).split(b"\0")
    files = {}
    for raw in tracked:
        if not raw:
            continue
        relative = raw.decode("utf-8")
        path = pathlib.PurePosixPath(relative)
        if relative not in RUNTIME_PATHS and relative not in {"LICENSE", "THIRD_PARTY_NOTICES.txt"}:
            continue
        if path.name in FORBIDDEN_NAMES or path.suffix in FORBIDDEN_SUFFIXES:
            raise ValueError(f"Refusing credential or generated file: {relative}")
        source = project / relative
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Refusing non-regular source: {relative}")
        contents = source.read_bytes()
        if SECRET_PATTERN.search(contents):
            raise ValueError(f"Potential embedded credential in {relative}")
        files[relative] = contents
    if not RUNTIME_PATHS <= files.keys() or not {"LICENSE", "THIRD_PARTY_NOTICES.txt"} <= files.keys():
        raise ValueError("Tracked runtime payload is incomplete")
    for name in BINARIES:
        source = project / "build" / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Missing compiled product: {source}")
        files[f"build/{name}"] = source.read_bytes()
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=project, text=True).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Cannot identify release source commit")
    files["RELEASE.json"] = (json.dumps({"tag": tag, "platform": "ubuntu24.04-amd64", "commit": commit}, separators=(",", ":")) + "\n").encode("ascii")
    if len(files) > MAX_MEMBERS or sum(map(len, files.values())) > MAX_TOTAL_SIZE:
        raise ValueError("Release exceeds size limit")
    manifest = "".join(f"{hashlib.sha256(data).hexdigest()}  {name}\n" for name, data in sorted(files.items()))
    files["SHA256SUMS"] = manifest.encode("ascii")
    with tarfile.open(archive, "w:gz", format=tarfile.PAX_FORMAT) as bundle:
        for name, data in sorted(files.items()):
            info = tarfile.TarInfo(f"{root}/{name}")
            info.size = len(data)
            info.mode = 0o755 if name.startswith("build/") or name.endswith(".sh") or name == "deploy/release_bundle.py" else 0o644
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            bundle.addfile(info, io.BytesIO(data))
    checksum = digest(archive.open("rb"))
    (output / f"{archive.name}.sha256").write_text(f"{checksum}  {archive.name}\n", encoding="ascii")
    print(archive)


def verify(archive):
    # tarfile can stop at the final tar member without reading gzip's CRC trailer.
    expanded = 0
    with gzip.open(archive, "rb") as compressed:
        while chunk := compressed.read(1024 * 1024):
            expanded += len(chunk)
            if expanded > MAX_TOTAL_SIZE + MAX_MEMBERS * 2048:
                raise ValueError("Expanded release exceeds size limit")
    total = 0
    files = {}
    root = None
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        if len(members) > MAX_MEMBERS:
            raise ValueError("Too many release entries")
        for member in members:
            parts = pathlib.PurePosixPath(member.name).parts
            if len(parts) < 2 or any(part in ("", ".", "..") for part in parts):
                raise ValueError("Unsafe release path")
            if root is None:
                root = parts[0]
            if parts[0] != root or not ROOT_PATTERN.fullmatch(root):
                raise ValueError("Invalid release root")
            if not member.isfile() or member.size > MAX_FILE_SIZE:
                raise ValueError("Only bounded regular files are allowed")
            relative = "/".join(parts[1:])
            if relative in files:
                raise ValueError("Duplicate release path")
            total += member.size
            if total > MAX_TOTAL_SIZE:
                raise ValueError("Release exceeds size limit")
            file = bundle.extractfile(member)
            if file is None:
                raise ValueError("Unreadable release entry")
            files[relative] = digest(file)
        manifest_file = bundle.extractfile(f"{root}/SHA256SUMS") if root else None
        if manifest_file is None:
            raise ValueError("Missing release manifest")
        manifest = manifest_file.read().decode("ascii")
    listed = {}
    for line in manifest.splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./@-]+)", line)
        if not match or match[2] in listed:
            raise ValueError("Invalid release manifest")
        listed[match[2]] = match[1]
    files.pop("SHA256SUMS", None)
    if files != listed:
        raise ValueError("Release manifest does not match archive contents")
    allowed = RUNTIME_REQUIRED | {f"build/{name}" for name in BINARIES}
    if any(name not in allowed for name in files):
        raise ValueError("Release contains non-runtime files")
    required = {f"build/{name}" for name in BINARIES} | RUNTIME_REQUIRED
    if not required <= files.keys():
        raise ValueError("Release is missing required files")
    with tarfile.open(archive, "r:gz") as bundle:
        metadata = json.load(bundle.extractfile(f"{root}/RELEASE.json"))
    if metadata.get("tag") != root.removeprefix("harbor-").removesuffix("-ubuntu24.04-amd64") or metadata.get("platform") != "ubuntu24.04-amd64" or not re.fullmatch(r"[0-9a-f]{40}", metadata.get("commit", "")):
        raise ValueError("Release metadata does not match archive")
    return root


def extract(archive, destination):
    root = verify(archive)
    if destination.is_symlink() or not destination.is_dir() or any(destination.iterdir()):
        raise ValueError("Extraction destination must be an empty directory")
    with tarfile.open(archive, "r:gz") as bundle:
        bundle.extractall(destination, filter="data")
    print(destination / root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    maker = sub.add_parser("create")
    maker.add_argument("tag")
    maker.add_argument("output", type=pathlib.Path)
    checker = sub.add_parser("verify")
    checker.add_argument("archive", type=pathlib.Path)
    unpacker = sub.add_parser("extract")
    unpacker.add_argument("archive", type=pathlib.Path)
    unpacker.add_argument("destination", type=pathlib.Path)
    args = parser.parse_args()
    if args.operation == "create":
        create(args.tag, args.output)
    elif args.operation == "verify":
        print(verify(args.archive))
    else:
        extract(args.archive, args.destination)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, tarfile.TarError, UnicodeError) as error:
        sys.exit(f"Release bundle error: {error}")
