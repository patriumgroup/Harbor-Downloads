"""Authenticated identity bridge on the protected pgAdmin Unix socket.

The proxy secret is separate from all panel/database credentials. The public
proxy must overwrite both identity and secret headers on every request.
"""
import hmac
import hashlib
import base64
from http.cookies import SimpleCookie
import os
import re
from pgAdmin4 import app as pgadmin_app
admin_tool = os.environ.get('HARBOR_PGADMIN_ROLE') == 'admin'
if os.environ.get("HARBOR_TOOL_SSO")=="1":
    import pg_sso
    pg_sso.register(pgadmin_app)

def application(environ, start_response):
    identity = environ.pop('HTTP_X_HARBOR_OWNER', '')
    supplied = environ.pop('HTTP_X_HARBOR_PROXY_SECRET', '')
    secret = os.environ.get('HARBOR_PGADMIN_PROXY_SECRET', '')
    # Remove every identity source pgAdmin might otherwise use as a fallback.
    for key in tuple(environ):
        normalized = key.upper().replace('-', '_')
        if normalized in {'REMOTE_USER', 'HTTP_REMOTE_USER', 'HTTP_X_FORWARDED_USER', 'HTTP_X_HARBOR_OWNER', 'HTTP_X_HARBOR_PROXY_SECRET'}:
            environ.pop(key, None)
    valid_identity = identity == 'harboradmin' if admin_tool else bool(re.fullmatch(r'[a-z][a-z0-9]{0,15}', identity))
    if (environ.get('REMOTE_ADDR') not in ('', None) or len(secret) < 64
            or not hmac.compare_digest(supplied, secret)
            or not valid_identity):
        start_response('403 Forbidden', [('Content-Type', 'text/plain'), ('Cache-Control', 'no-store')])
        return [b'An authenticated Harbor owner is required.']
    assertion = environ.pop('HTTP_X_HARBOR_ASSERTION', '')
    if os.environ.get('HARBOR_TOOL_SSO') == '1':
        try:
            environ['harbor.credentials'] = pg_sso.credentials(identity, assertion)
            environ['harbor.owner'] = identity
        except Exception:
            start_response('503 Service Unavailable', [('Content-Type', 'text/plain'), ('Cache-Control', 'no-store')])
            return [b'SSO provisioning unavailable. Return to the panel.']
    environ['REMOTE_USER'] = identity
    environ['SCRIPT_NAME'] = '/tools/admin/pgadmin' if admin_tool else '/tools/pgadmin'
    environ['wsgi.url_scheme'] = 'https'
    # Bind the third-party application's cookie to the authenticated owner.
    # Switching panel users in one browser must not reuse another user's pgAdmin
    # session. The HMAC also rejects copying a cookie into a different owner slot.
    canonical = 'harbor_admin_pgadmin' if admin_tool else 'harbor_pgadmin'
    scoped = canonical + '_' + identity
    cookies = SimpleCookie()
    try:
        cookies.load(environ.get('HTTP_COOKIE', ''))
    except Exception:
        cookies.clear()
    filtered = SimpleCookie()
    for name, cookie in cookies.items():
        if not name.startswith(canonical):
            filtered[name] = cookie.value
    token = cookies[scoped].value if scoped in cookies else ''
    if token and len(token) <= 8192:
        try:
            encoded, signature = token.rsplit('.', 1)
            raw = base64.urlsafe_b64decode(encoded + '=' * (-len(encoded) % 4)).decode('utf-8')
            expected = hmac.new(secret.encode(), (identity + '\0' + raw).encode(), hashlib.sha256).hexdigest()
            if hmac.compare_digest(signature, expected):
                filtered[canonical] = raw
        except Exception:
            pass
    environ['HTTP_COOKIE'] = '; '.join(cookie.OutputString() for cookie in filtered.values())

    def respond(status, headers, exc_info=None):
        bound = []
        for name, value in headers:
            if name.lower() == 'set-cookie':
                parsed = SimpleCookie()
                parsed.load(value)
                if canonical in parsed:
                    original = parsed[canonical]
                    signature = hmac.new(secret.encode(), (identity + '\0' + original.value).encode(), hashlib.sha256).hexdigest()
                    envelope = base64.urlsafe_b64encode(original.value.encode()).decode().rstrip('=') + '.' + signature
                    outgoing = SimpleCookie()
                    outgoing[scoped] = envelope
                    for attribute in original.keys():
                        if original[attribute]:
                            outgoing[scoped][attribute] = original[attribute]
                    value = outgoing[scoped].OutputString()
            bound.append((name, value))
        return start_response(status, bound, exc_info)

    return pgadmin_app(environ, respond)
