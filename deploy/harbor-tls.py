#!/usr/bin/env python3
"""Root-only NGINX vhost and HTTP-01 certificate helper for Harbor."""
import ipaddress
import json
import http.client
import os
import pathlib
import re
import socket
import stat
import subprocess
import sys
import tempfile
import secrets
import time
from contextlib import contextmanager
from functools import wraps

FQDN = re.compile(r"(?=.{4,253}$)[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+\Z")
OWNER = re.compile(r"[a-z][a-z0-9-]{1,30}\Z")
SITES = pathlib.Path("/etc/nginx/sites-available")
ENABLED = pathlib.Path("/etc/nginx/sites-enabled")
ACME = pathlib.Path("/var/www/harbor-acme")
STATUS = pathlib.Path("/var/lib/harbor/tls-status")
LOCKS = pathlib.Path("/var/lib/harbor/tls-locks")
SELF = pathlib.Path("/etc/harbor/self-signed")
CERTBOT = "/usr/bin/certbot"


def domain(value):
    if not FQDN.fullmatch(value) or any(len(part) > 63 for part in value.split(".")):
        raise ValueError("A lowercase, complete DNS hostname is required")
    try:
        ipaddress.ip_address(value)
    except ValueError:
        return value
    raise ValueError("A DNS hostname, not an IP address, is required")


def run(argv, timeout=30):
    return subprocess.run(argv, check=True, timeout=timeout)


def write(path, value, mode=0o644):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError(f"Unsafe managed file: {path}")
    descriptor, temporary = tempfile.mkstemp(prefix=".harbor-", dir=path.parent)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(value)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def directory(path, mode=0o755):
    path.mkdir(mode=mode, exist_ok=True)
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        info = os.fstat(descriptor)
        if info.st_uid != 0 or info.st_mode & 0o022:
            raise ValueError(f"Unsafe managed directory: {path}")
        # mkdir applies the caller's umask. The release installer uses 077, but
        # NGINX must be able to traverse root-owned HTTP-01 directories.
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


@contextmanager
def host_lock(host):
    import fcntl
    domain(host)
    directory(LOCKS, 0o700)
    descriptor = os.open(LOCKS / (host + ".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o077:
            raise ValueError("Unsafe website operation lock")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def locked_site(operation):
    @wraps(operation)
    def invoke(host, *args):
        with host_lock(host):
            return operation(host, *args)
    return invoke


def challenge(host):
    directory(ACME)
    root = ACME / host
    directory(root)
    directory(root / ".well-known")
    directory(root / ".well-known" / "acme-challenge")
    return root


def challenge_location(host):
    return ("location ^~ /.well-known/acme-challenge/ {\n"
            f"    root /var/www/harbor-acme/{host};\n"
            "    default_type text/plain;\n"
            "    modsecurity off;\n"
            "    try_files $uri =404;\n"
            "    limit_except GET HEAD { deny all; }\n"
            "}\n")


def binding_ip():
    config = pathlib.Path("/etc/harbor/harbor.env")
    if not config.exists():
        return ""
    content = config.read_text()
    for key in ("HARBOR_IP_ORIGIN", "HARBOR_ORIGIN"):
        values = re.findall(r"^" + key + r"=(\S+)$", content, re.M)
        if len(values) > 1:
            raise ValueError("Duplicate panel origin")
        if not values:
            continue
        value = values[0]
        if value.startswith("https://"):
            try:
                return str(ipaddress.IPv4Address(value[8:]))
            except ValueError:
                if key == "HARBOR_IP_ORIGIN":
                    raise ValueError("Invalid panel fallback IP origin")
        elif key == "HARBOR_IP_ORIGIN":
            raise ValueError("Invalid panel fallback IP origin")
    return ""


def listen(ip, port, ssl=False):
    return f"listen {ip + ':' if ip else ''}{port}{' ssl' if ssl else ''};"


def verify_challenge(host, ip):
    token = "harbor-route-" + secrets.token_hex(16)
    path = challenge(host) / ".well-known" / "acme-challenge" / token
    expected = "harbor-route-ok-" + token
    write(path, expected, 0o644)
    try:
        for _ in range(10):
            client = None
            try:
                client = http.client.HTTPConnection(ip or "127.0.0.1", 80, timeout=0.5)
                client.request("GET", "/.well-known/acme-challenge/" + token, headers={"Host": host})
                response = client.getresponse()
                body = response.read(512)
                if response.status == 200 and body.decode() == expected:
                    return
            except (OSError, UnicodeError):
                pass
            finally:
                if client is not None:
                    client.close()
            time.sleep(0.2)
        raise ValueError("The HTTP-01 challenge route did not serve the expected token after NGINX reload")
    finally:
        path.unlink(missing_ok=True)


def managed_config(path, content, host, ip):
    old = path.read_text() if path.exists() and not path.is_symlink() else None
    write(path, content)
    try:
        run(["/usr/sbin/nginx", "-t"])
        run(["/usr/bin/systemctl", "reload", "nginx.service"])
        verify_challenge(host, ip)
    except Exception:
        if old is None:
            path.unlink(missing_ok=True)
        else:
            write(path, old)
        try:
            run(["/usr/sbin/nginx", "-t"])
            run(["/usr/bin/systemctl", "reload", "nginx.service"])
        except Exception:
            pass
        raise


def hostname_in_use(host):
    result = subprocess.run(["/usr/sbin/nginx", "-T"], capture_output=True, text=True, check=True)
    return bool(re.search(r"\bserver_name\s+" + re.escape(host) + r"(?:\s|;)", result.stdout))


def ensure_self_signed(host, ip):
    directory(SELF, 0o700)
    certificate, key = SELF / "panel.crt", SELF / "panel.key"
    if certificate.exists() and key.exists():
        for path in (certificate, key):
            info = path.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o022:
                raise ValueError("Unsafe fallback certificate")
        if key.stat().st_mode & 0o077:
            raise ValueError("Fallback private key is readable by another account")
        return certificate, key
    if certificate.exists() or key.exists() or certificate.is_symlink() or key.is_symlink():
        raise ValueError("Incomplete or unsafe fallback certificate")
    extensions = "DNS:" + host + (",IP:" + ip if ip else "")
    run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:3072", "-sha256", "-nodes",
         "-days", "365", "-subj", "/CN=" + host, "-addext", "subjectAltName=" + extensions,
         "-keyout", str(key), "-out", str(certificate)], 60)
    os.chmod(key, 0o600)
    os.chmod(certificate, 0o644)
    return certificate, key


def proxy(host):
    return ("proxy_pass http://harbor_gateway;\nproxy_http_version 1.1;\n"
            f"proxy_set_header Host {host};\nproxy_set_header Connection \"\";\n"
            "include /etc/harbor/nginx-proxy-secret.conf;\n"
            "proxy_connect_timeout 3s;\nproxy_read_timeout 60s;\n")


def panel_config(host, ip, public=False):
    fallback, fallback_key = ensure_self_signed(host, ip)
    certificate = f"/etc/letsencrypt/live/{host}/fullchain.pem" if public else fallback.as_posix()
    key = f"/etc/letsencrypt/live/{host}/privkey.pem" if public else fallback_key.as_posix()
    result = ("# Managed by Harbor. Do not edit in place.\n"
              f"server {{ {listen(ip, 80)} server_name {host};\n"
              f"if ($host != {host}) {{ return 421; }}\n{challenge_location(host)}"
              f"location / {{ return 301 https://{host}$request_uri; }}\n}}\n"
              f"server {{ {listen(ip, 443, True)} server_name {host};\n"
              f"if ($host != {host}) {{ return 421; }}\n"
              f"ssl_certificate {certificate};\nssl_certificate_key {key};\n"
              "ssl_protocols TLSv1.2 TLSv1.3; server_tokens off;\n"
              "access_log /var/log/nginx/harbor-panel-access.json harbor_panel;\n"
              "error_log /var/log/nginx/harbor-panel-error.log warn;\n"
              "client_max_body_size 4k; client_body_timeout 5s;\n"
              "include /etc/harbor/nginx-basic.conf;\n")
    if public:
        result += 'add_header Strict-Transport-Security "max-age=31536000" always;\n'
    result += ("location = /api/login {\nlimit_req zone=harbor_login burst=5 nodelay;\n"
               "limit_req_status 429; access_log /var/log/nginx/harbor-login.log harbor_login;\n"
               + proxy(host) + "}\nlocation / {\n" + proxy(host) + "}\n}\n")
    if ip:
        fallback_block = (f"server {{ {listen(ip, 443, True)} server_name {ip};\n"
                   f"if ($host != {ip}) {{ return 421; }}\n"
                   f"ssl_certificate {fallback.as_posix()};\nssl_certificate_key {fallback_key.as_posix()};\n"
                   "ssl_protocols TLSv1.2 TLSv1.3; server_tokens off;\n"
                   "include /etc/harbor/nginx-basic.conf;\n"
                   "location = /api/login { limit_req zone=harbor_login burst=5 nodelay; "
                   "limit_req_status 429; " + proxy(ip) + "}\n"
                   "location / {\n" + proxy(ip) + "}\n}\n")
        # Browsers may omit SNI for an IP literal. Keep the fallback certificate
        # first so the no-SNI handshake still presents an IP SAN after panel LE.
        marker = f"server {{ {listen(ip, 443, True)} server_name {host};"
        result = result.replace(marker, fallback_block + marker, 1)
    return result


def panel_setup(host, ip):
    domain(host)
    if ip:
        ipaddress.IPv4Address(ip)
    challenge(host)
    path = ENABLED / "harbor-panel.conf"
    if path.is_symlink() and not path.exists():
        raise ValueError("Broken managed panel vhost symlink")
    if not path.exists() and hostname_in_use(host):
        raise ValueError("Panel hostname is already used by an active NGINX vhost")
    if path.exists() and not path.is_symlink():
        raise ValueError("Panel configuration path is not a managed symlink")
    if not path.exists():
        target = SITES / "harbor-panel.conf"
        write(target, panel_config(host, ip))
        path.symlink_to(target)
        try:
            run(["/usr/sbin/nginx", "-t"])
            run(["/usr/bin/systemctl", "reload", "nginx.service"])
            verify_challenge(host, ip)
        except Exception:
            path.unlink(missing_ok=True)
            target.unlink(missing_ok=True)
            try:
                run(["/usr/sbin/nginx", "-t"])
                run(["/usr/bin/systemctl", "reload", "nginx.service"])
            except Exception:
                pass
            raise


def site_config(host, owner, secure=False, ip=""):
    root = f"/srv/harbor-sites/{host}/public"
    certificate = f"/etc/letsencrypt/live/{host}"
    common = ("server_tokens off;\n"
              f"root {root};\nindex index.html index.php;\n"
              "disable_symlinks on from=$document_root;\n"
              f"include /etc/harbor/waf-sites/{host}.conf;\n"
              "location ~ /\\. { deny all; }\n"
              "location / { try_files $uri $uri/ =404; }\n"
              f"location ~ \\.php$ {{ try_files $uri =404; include /etc/nginx/fastcgi.conf; include /etc/harbor/php-sites/{host}.conf; }}\n")
    http = f"server {{ {listen(ip, 80)}\nserver_name {host};\n{challenge_location(host)}"
    if secure:
        http += f"location / {{ return 301 https://{host}$request_uri; }}\n}}\n"
        return http + (f"server {{ {listen(ip, 443, True)}\nserver_name {host};\nssl_certificate {certificate}/fullchain.pem;\n"
                       f"ssl_certificate_key {certificate}/privkey.pem;\n"
                       "ssl_protocols TLSv1.2 TLSv1.3;\n" + common + "}\n")
    return http + common + "}\n"


@locked_site
def site_setup(host, owner):
    import grp
    import pwd
    domain(host)
    if not OWNER.fullmatch(owner):
        raise ValueError("Invalid owner")
    if allocated(host) != owner:
        raise ValueError("Hostname is not allocated to this owner")
    account = pwd.getpwnam(owner)
    registry = json.loads(pathlib.Path("/var/lib/harbor/owners.json").read_text())
    if account.pw_uid < 1000 or account.pw_dir != "/home/" + owner or registry["owners"][owner]["uid"] != account.pw_uid:
        raise ValueError("Unsafe native site owner")
    directory(pathlib.Path("/srv/harbor-sites"))
    home = pathlib.Path("/srv/harbor-sites") / host
    directory(home, 0o711)
    public = home / "public"
    if not public.exists():
        public.mkdir(mode=0o755)
        os.chown(public, account.pw_uid, account.pw_gid)
    if public.is_symlink() or not public.is_dir() or public.stat().st_uid != account.pw_uid or public.stat().st_mode & 0o002:
        raise ValueError("Unsafe site document root")
    challenge(host)
    for folder in (pathlib.Path("/etc/harbor/waf-sites"), pathlib.Path("/etc/harbor/php-sites")):
        directory(folder)
    logs = pathlib.Path("/var/log/harbor-sites")
    if not logs.exists():
        logs.mkdir(mode=0o750)
        os.chown(logs, 0, grp.getgrnam("www-data").gr_gid)
    directory(logs, 0o750)
    if logs.stat().st_gid != grp.getgrnam("www-data").gr_gid:
        raise ValueError("Unsafe site log directory group")
    waf = pathlib.Path("/etc/harbor/waf-sites") / (host + ".conf")
    php = pathlib.Path("/etc/harbor/php-sites") / (host + ".conf")
    if not waf.exists() or (not waf.is_symlink() and waf.read_text() == "return 503;\n"):
        write(waf, ("limit_req zone=harbor_requests burst=40 nodelay;\nlimit_req_status 429;\n"
                    f"access_log /var/log/harbor-sites/{owner}.{host}.access.json harbor_site;\n"
                    f"error_log /var/log/harbor-sites/{owner}.{host}.error.log warn;\n"))
    if not php.exists() or (not php.is_symlink() and php.read_text() == "return 503;\n"):
        write(php, "return 404;\n")
    for snippet in (waf, php):
        info = snippet.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_nlink != 1 or info.st_mode & 0o022:
            raise ValueError("Unsafe managed website include")
    for kind, suffix in (("access", ".json"), ("error", ".log")):
        log = pathlib.Path("/var/log/harbor-sites") / f"{owner}.{host}.{kind}{suffix}"
        if log.is_symlink() or (log.exists() and (not log.is_file() or log.stat().st_uid != 0 or log.stat().st_nlink != 1 or log.stat().st_mode & 0o027)):
            raise ValueError("Unsafe site log")
        log.touch(exist_ok=True, mode=0o640)
    path = ENABLED / ("harbor-site-" + host + ".conf")
    target = SITES / path.name
    if path.is_symlink() and not path.exists():
        raise ValueError("Broken managed website vhost symlink")
    if path.exists() and (not path.is_symlink() or path.resolve() != target):
        raise ValueError("Website vhost path is already occupied")
    if not path.exists():
        if hostname_in_use(host):
            raise ValueError("Website hostname is already used by an active NGINX vhost")
        write(target, site_config(host, owner, ip=binding_ip()))
        path.symlink_to(target)
        try:
            run(["/usr/sbin/nginx", "-t"])
            run(["/usr/bin/systemctl", "reload", "nginx.service"])
            verify_challenge(host, binding_ip())
        except Exception:
            path.unlink(missing_ok=True)
            target.unlink(missing_ok=True)
            try:
                run(["/usr/sbin/nginx", "-t"])
                run(["/usr/bin/systemctl", "reload", "nginx.service"])
            except Exception:
                pass
            raise
        previous_status = STATUS / (host + ".json")
        if previous_status.is_file() and not previous_status.is_symlink():
            previous_status.unlink()
    else:
        existing = target.read_text()
        secure = f"ssl_certificate /etc/letsencrypt/live/{host}/fullchain.pem;" in existing
        expected = site_config(host, owner, secure, binding_ip())
        if existing != expected:
            managed_config(target, expected, host, binding_ip())
        else:
            verify_challenge(host, binding_ip())


@locked_site
def site_retire(host):
    domain(host)
    path = ENABLED / ("harbor-site-" + host + ".conf")
    target = SITES / path.name
    if not path.exists() and not path.is_symlink():
        return
    if not path.is_symlink() or path.resolve() != target:
        raise ValueError("Managed website vhost is missing")
    path.unlink()
    try:
        run(["/usr/sbin/nginx", "-t"])
        run(["/usr/bin/systemctl", "reload", "nginx.service"])
    except Exception:
        path.symlink_to(target)
        raise
    target.unlink(missing_ok=True)
    status(host, "retired")


def allocated(host):
    domain(host)
    data = json.loads(pathlib.Path("/var/lib/harbor/owners.json").read_text())
    for entry in data.get("domains", []):
        if host == entry["name"]:
            return entry["owner"]
        for grant in entry.get("delegations", []):
            if host == grant["label"] + "." + entry["name"]:
                return grant["target"]
    raise ValueError("Hostname is not allocated")


def reconcile():
    data = json.loads(pathlib.Path("/var/lib/harbor/owners.json").read_text())
    failures = []
    for entry in data.get("domains", []):
        hosts = [(entry["name"], entry["owner"])]
        hosts.extend((grant["label"] + "." + entry["name"], grant["target"])
                     for grant in entry.get("delegations", []))
        for host, owner in hosts:
            try:
                site_setup(host, owner)
            except Exception as error:
                failures.append(f"{host}: {error}")
    if failures:
        raise ValueError("Some website vhosts need review: " + "; ".join(failures))


def status(host, phase, detail=""):
    directory(STATUS, 0o700)
    write(STATUS / (host + ".json"), json.dumps({"state": phase, "detail": detail}) + "\n", 0o600)


def issue(host, panel=False):
    domain(host)
    if panel:
        env = pathlib.Path("/etc/harbor/harbor.env").read_text()
        if "HARBOR_ORIGIN=https://" + host + "\n" not in env:
            raise ValueError("Panel hostname does not match the installed origin")
    else:
        owner = allocated(host)
        if not (ENABLED / ("harbor-site-" + host + ".conf")).is_symlink():
            raise ValueError("Managed website vhost is missing")
    email_path = pathlib.Path("/etc/harbor/acme-email")
    email_stat = email_path.lstat()
    if not stat.S_ISREG(email_stat.st_mode) or email_stat.st_uid != 0 or email_stat.st_nlink != 1 or email_stat.st_mode & 0o077 or email_stat.st_size > 256:
        raise ValueError("Unsafe ACME contact email file")
    email = email_path.read_text().strip()
    if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", email):
        raise ValueError("Set a valid ACME contact email during installation")
    status(host, "running")
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(host, 80, type=socket.SOCK_STREAM)}
        if not addresses or not all(ipaddress.ip_address(address).is_global for address in addresses):
            raise ValueError("Public A/AAAA DNS records are required for Let's Encrypt HTTP verification")
        run([CERTBOT, "certonly", "--webroot", "-w", str(challenge(host)), "-d", host,
             "--non-interactive", "--agree-tos", "--email", email, "--keep-until-expiring"], 300)
        path = SITES / ("harbor-panel.conf" if panel else "harbor-site-" + host + ".conf")
        if panel:
            env = pathlib.Path("/etc/harbor/harbor.env").read_text()
            match = re.search(r"^HARBOR_IP_ORIGIN=https://([^\n]+)$", env, re.M)
            content = panel_config(host, match.group(1) if match else "", True)
        else:
            content = site_config(host, owner, True, binding_ip())
        if panel:
            managed_config(path, content, host, binding_ip())
            status(host, "active")
        else:
            with host_lock(host):
                if allocated(host) != owner:
                    raise ValueError("Website allocation changed during certificate issuance")
                if not (ENABLED / ("harbor-site-" + host + ".conf")).is_symlink():
                    raise ValueError("Managed website vhost was retired during certificate issuance")
                managed_config(path, content, host, binding_ip())
                status(host, "active")
    except Exception as error:
        still_owned = panel
        if not panel:
            try:
                still_owned = allocated(host) == owner
            except ValueError:
                still_owned = False
        if still_owned:
            detail = str(error) if isinstance(error, ValueError) else "Certificate request or configuration validation failed; ask the administrator to check the certificate service log"
            status(host, "failed", detail[:200])
        raise


def main():
    if os.geteuid() != 0:
        raise ValueError("Root is required")
    command, *args = sys.argv[1:]
    if command == "panel-setup" and len(args) == 2:
        panel_setup(*args)
    elif command == "site-setup" and len(args) == 2:
        site_setup(*args)
    elif command == "site-retire" and len(args) == 1:
        site_retire(args[0])
    elif command == "reconcile" and not args:
        reconcile()
    elif command == "issue-panel" and len(args) == 1:
        issue(args[0], True)
    elif command == "issue-site" and len(args) == 1:
        issue(args[0])
    elif command == "set-email" and len(args) == 1:
        if not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", args[0]) or len(args[0]) > 254:
            raise ValueError("Invalid ACME contact email")
        write(pathlib.Path("/etc/harbor/acme-email"), args[0] + "\n", 0o600)
    elif command == "renew-deploy" and not args:
        run(["/usr/sbin/nginx", "-t"])
        run(["/usr/bin/systemctl", "reload", "nginx.service"])
    else:
        raise ValueError("Invalid TLS operation")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
