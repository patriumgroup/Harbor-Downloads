#!/usr/bin/env python3
"""Fixed-repository Harbor release checks and updates for the systemd worker."""

import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


REPOSITORY = "patriumgroup/Harbor"
API = f"https://api.github.com/repos/{REPOSITORY}"
TOKEN_FILE = pathlib.Path("/etc/harbor/github-release-token")
INSTALLED_FILE = pathlib.Path("/usr/local/share/harbor/release.json")
STATE_FILE = pathlib.Path("/var/lib/harbor/release-state.json")
LOG_FILE = pathlib.Path("/var/log/harbor-updates.jsonl")
TAG = re.compile(r"v(\d+)\.(\d+)\.(\d+)(?:-(alpha|beta)\.(\d+))?")
TOKEN = re.compile(r"(?:github_pat_|ghp_)[A-Za-z0-9_]{20,255}")
MAX_ASSET = 100 * 1024 * 1024
ASSET_HOSTS = {"release-assets.githubusercontent.com", "objects.githubusercontent.com"}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        return None


OPENER = urllib.request.build_opener(NoRedirect())


def root_file(path, maximum=65536):
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o077 or info.st_size > maximum:
            raise ValueError("Unsafe protected release file")
        data = bytearray()
        while chunk := os.read(descriptor, min(4096, maximum + 1 - len(data))):
            data.extend(chunk)
            if len(data) > maximum:
                raise ValueError("Protected release file exceeds limit")
        return bytes(data)
    finally:
        os.close(descriptor)


def token():
    try:
        value = root_file(TOKEN_FILE, 512).decode("ascii").strip()
    except FileNotFoundError:
        return ""
    if not TOKEN.fullmatch(value):
        raise ValueError("Invalid repository token file")
    return value


def installed_tag():
    try:
        value = json.loads(root_file(INSTALLED_FILE, 4096))
    except FileNotFoundError:
        return ""
    tag = value.get("tag", "")
    return tag if isinstance(tag, str) and TAG.fullmatch(tag) else ""


def version(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError("Unsupported release tag")
    major, minor, patch, stage, number = match.groups()
    return (int(major), int(minor), int(patch), {"alpha": 0, "beta": 1, None: 2}[stage], int(number or 0))


def write_state(**values):
    STATE_FILE.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    data = {"repository": REPOSITORY, "time": int(time.time()), **values}
    raw = (json.dumps(data, separators=(",", ":")) + "\n").encode("utf-8")
    descriptor, name = tempfile.mkstemp(prefix="release-state.", dir=STATE_FILE.parent)
    try:
        os.fchmod(descriptor, 0o600)
        position = 0
        while position < len(raw):
            position += os.write(descriptor, raw[position:])
        os.fsync(descriptor)
        os.close(descriptor)
        os.replace(name, STATE_FILE)
        directory = os.open(STATE_FILE.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except BaseException:
        try:
            os.close(descriptor)
        except OSError:
            pass
        pathlib.Path(name).unlink(missing_ok=True)
        raise


def log(action, state, message):
    descriptor = os.open(LOG_FILE, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o077:
            raise ValueError("Unsafe update log")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        row = {"time": int(time.time() * 1000), "action": action, "service": "harbor-release", "state": state, "message": message[:500]}
        data = (json.dumps(row, separators=(",", ":")) + "\n").encode()
        position = 0
        while position < len(data):
            position += os.write(descriptor, data[position:])
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def request(url, credential="", accept="application/vnd.github+json"):
    headers = {"User-Agent": "Harbor-Release-Manager", "Accept": accept, "X-GitHub-Api-Version": "2022-11-28"}
    if credential:
        headers["Authorization"] = f"Bearer {credential}"
    return urllib.request.Request(url, headers=headers)


def read_limited(response, limit):
    data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("GitHub response exceeds limit")
    return data


def api_json(url, credential):
    if not url.startswith(API + "/"):
        raise ValueError("GitHub API path is not allowed")
    try:
        with OPENER.open(request(url, credential), timeout=20) as response:
            return json.loads(read_limited(response, 2 * 1024 * 1024))
    except urllib.error.HTTPError as error:
        if error.code in (401, 403, 404):
            raise ValueError("Repository access failed. Configure a Contents: read token if Harbor is private") from None
        raise ValueError(f"GitHub API returned HTTP {error.code}") from None


def releases(credential):
    result = api_json(f"{API}/releases?per_page=30", credential)
    if not isinstance(result, list):
        raise ValueError("Invalid GitHub release listing")
    return result


def newest_release(rows):
    accepted = [row for row in rows if isinstance(row, dict) and not row.get("draft")
                and isinstance(row.get("tag_name"), str) and TAG.fullmatch(row["tag_name"])
                and bool(row.get("prerelease")) == ("-" in row["tag_name"])]
    if not accepted:
        raise ValueError("No Harbor release is available")
    return max(accepted, key=lambda row: version(row["tag_name"]))


def release_assets(release):
    tag = release["tag_name"]
    prefix = f"harbor-{tag}-ubuntu24.04-amd64.tar.gz"
    rows = release.get("assets", [])
    if not isinstance(rows, list):
        raise ValueError("Release assets are missing")
    found = {}
    for row in rows:
        if not isinstance(row, dict) or row.get("name") not in (prefix, prefix + ".sha256"):
            continue
        if row["name"] in found or row.get("state") != "uploaded" or not isinstance(row.get("id"), int):
            raise ValueError("Invalid release asset")
        if not isinstance(row.get("size"), int) or not 0 < row["size"] <= MAX_ASSET:
            raise ValueError("Invalid release asset size")
        found[row["name"]] = row
    if set(found) != {prefix, prefix + ".sha256"}:
        raise ValueError("Release must contain an Ubuntu archive and checksum")
    return prefix, found[prefix], found[prefix + ".sha256"]


def download_asset(asset, credential):
    url = f"{API}/releases/assets/{asset['id']}"
    try:
        response = OPENER.open(request(url, credential, "application/octet-stream"), timeout=30)
    except urllib.error.HTTPError as error:
        if error.code not in (302, 303, 307):
            raise ValueError(f"Release asset request returned HTTP {error.code}") from None
        location = error.headers.get("Location", "")
        target = urllib.parse.urlsplit(location)
        if target.scheme != "https" or target.hostname not in ASSET_HOSTS or target.username or target.password or target.port not in (None, 443):
            raise ValueError("GitHub asset redirect is not allowed")
        # GitHub's signed asset URL does not receive the repository token.
        try:
            response = OPENER.open(request(location), timeout=30)
        except urllib.error.HTTPError as second:
            raise ValueError(f"Signed asset download returned HTTP {second.code}") from None
    with response:
        if response.status != 200 or response.headers.get("Content-Type", "").startswith("application/json"):
            raise ValueError("GitHub did not return a release file")
        data = read_limited(response, MAX_ASSET)
    if len(data) != asset["size"]:
        raise ValueError("Downloaded release size differs from GitHub metadata")
    declared = asset.get("digest", "")
    if declared and declared != "sha256:" + hashlib.sha256(data).hexdigest():
        raise ValueError("GitHub asset digest mismatch")
    return data


def available(credential):
    release = newest_release(releases(credential))
    release_assets(release)
    tag = release["tag_name"]
    return release, tag, f"https://github.com/{REPOSITORY}/releases/tag/{tag}"


def apply(release, credential, current):
    tag = release["tag_name"]
    prefix, archive_asset, digest_asset = release_assets(release)
    write_state(status="downloading", installedTag=current, availableTag=tag)
    with tempfile.TemporaryDirectory(prefix="harbor-release.", dir="/var/tmp") as temporary:
        directory = pathlib.Path(temporary)
        archive = directory / prefix
        sidecar = download_asset(digest_asset, credential)
        if len(sidecar) > 256:
            raise ValueError("Invalid release checksum")
        match = re.fullmatch(rb"([0-9a-f]{64})  " + re.escape(prefix.encode()) + rb"\n", sidecar)
        if not match:
            raise ValueError("Invalid release checksum format")
        digest = match[1].decode("ascii")
        archive.write_bytes(download_asset(archive_asset, credential))
        archive.chmod(0o600)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != digest:
            raise ValueError("Release checksum mismatch")
        manager = pathlib.Path("/usr/local/lib/harbor")
        subprocess.run([sys.executable, str(manager / "release_bundle.py"), "verify", str(archive)],
                       check=True, stdout=subprocess.DEVNULL, timeout=90)
        # The installer replaces the installed updater. Run a protected copy so
        # Bash cannot read a script while that same file is being overwritten.
        for name in ("release_bundle.py", "update.sh"):
            shutil.copy2(manager / name, directory / name)
        write_state(status="installing", installedTag=current, availableTag=tag)
        log("apply", "running", f"Installing {tag}")
        subprocess.run(["/bin/bash", str(directory / "update.sh"), str(archive), digest], check=True, timeout=1800)
    installed = installed_tag()
    if installed != tag:
        raise ValueError("Installer did not record the expected release tag")
    write_state(status="completed", installedTag=tag, availableTag=tag)
    log("apply", "completed", f"Installed {tag}")


def main(command):
    descriptor = os.open("/run/harbor-release-manager.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(descriptor)
        raise ValueError("A Harbor release operation is already running") from None
    try:
        current = installed_tag()
        credential = token()
        action = "apply" if command.startswith("apply-") else command
        log(action, "running", "Release worker started")
        release, tag, url = available(credential)
        newer = not current or version(tag) > version(current)
        write_state(status="available" if newer else "current", installedTag=current, availableTag=tag, releaseUrl=url)
        if command == "check":
            log("check", "completed", f"Latest release: {tag}")
            return
        if command == "auto" and not current:
            log("auto", "completed", "Automatic installation skipped until a versioned release is installed manually")
            return
        if not newer:
            log(action, "completed", "Already on the latest release")
            return
        if command.startswith("apply-") and command[6:] != tag:
            raise ValueError("Available release changed. Check again before installing")
        apply(release, credential, current)
    except Exception as error:
        message = str(error)[:300] or "Release operation failed"
        write_state(status="failed", installedTag=installed_tag(), message=message)
        log("apply" if command.startswith("apply-") else command, "failed", message)
        raise
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    if os.geteuid() != 0 or len(sys.argv) != 2 or not re.fullmatch(r"check|auto|apply-v[0-9]+\.[0-9]+\.[0-9]+(?:-(?:alpha|beta)\.[0-9]+)?", sys.argv[1]):
        sys.exit("Root and one fixed release command are required")
    try:
        main(sys.argv[1])
    except Exception as error:
        sys.exit(f"Harbor release operation failed: {error}")
