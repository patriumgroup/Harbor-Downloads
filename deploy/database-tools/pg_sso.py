"""Owner-scoped pgAdmin connection provisioning for pinned pgAdmin 9.18."""
import json,os,pathlib,re,socket,tempfile
admin_tool=os.environ.get('HARBOR_PGADMIN_ROLE')=='admin'

def credentials(owner,assertion):
    if not (owner=='harboradmin' if admin_tool else re.fullmatch(r'[a-z][a-z0-9]{0,15}',owner)) or not re.fullmatch(r'[0-9]{10}\.[a-f0-9]{64}',assertion):
        raise ValueError('Invalid tool identity')
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(30);client.connect('/run/harbor-agent/tools.sock')
        client.sendall(json.dumps({'owner':owner,'tool':'admin-pgadmin' if admin_tool else 'pgadmin','assertion':assertion}).encode()+b'\n')
        wire=client.makefile('rb').readline(65537)
        if not wire.endswith(b'\n') or len(wire)>65536:raise ValueError('Invalid SSO response')
        reply=json.loads(wire)
        if not reply.get('ok'):raise ValueError('SSO provisioning unavailable')
        result=reply['data']
        if result['username']!=('harbor_admin_pg' if admin_tool else owner+'_panel') or not re.fullmatch('[a-f0-9]{64}',result['password']):raise ValueError('Invalid SSO credential')
        if not admin_tool and any(not re.fullmatch(re.escape(owner)+r'_[a-z][a-z0-9_]{0,14}',db) for db in result['databases']):raise ValueError('Invalid database scope')
        return result

def safe_route(method,path):
    # Connection definitions are managed by Harbor. This also keeps user-selected
    # passfiles/services/tunnels out of a shared application process.
    return not (method not in {'GET','HEAD','OPTIONS'} and
                (re.search(r'/browser/server/obj(?:/|$)',path) or '/import_export_servers' in path))

def register(app):
    import fcntl
    from flask import request,abort
    from flask_security import current_user
    from pgadmin.model import db,Server,ServerGroup
    @app.before_request
    def scoped_server():
        identity=request.environ.get('harbor.owner','')
        if not current_user.is_authenticated or not identity:return
        # pgAdmin Webserver identities use username; email is optional and may
        # be NULL. Never accept a matching internal/bootstrap identity here.
        if current_user.username!=identity or current_user.auth_source!='webserver':abort(403)
        values=request.environ.get('harbor.credentials')
        if not values:abort(503)
        if not safe_route(request.method,request.path):abort(403)
        if not values['databases'] and not admin_tool:
            if (request.view_args or {}).get('sid') is not None:abort(403)
            return
        directory=pathlib.Path('/var/lib/harbor-admin-pgadmin/storage' if admin_tool else '/var/lib/harbor-pgadmin/storage')/identity
        directory.mkdir(mode=0o700,parents=True,exist_ok=True)
        if directory.is_symlink():abort(503)
        os.chmod(directory,0o700)
        descriptor=os.open(directory/'.harbor-sso-lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
        with os.fdopen(descriptor,'a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            # libpq reads this server-side; no password is stored in the pgAdmin DB.
            passfile=directory/'.harbor.pgpass'
            fd,temporary=tempfile.mkstemp(prefix='.sso-',dir=directory)
            try:
                with os.fdopen(fd,'w') as output:
                    output.write('127.0.0.1:5432:*:'+values['username']+':'+values['password']+'\n')
                    output.flush();os.fsync(output.fileno())
                os.replace(temporary,passfile)
            finally:
                if os.path.exists(temporary):os.unlink(temporary)
            group=ServerGroup.query.filter_by(user_id=current_user.id,name='Harbor').first()
            if group is None:
                group=ServerGroup(user_id=current_user.id,name='Harbor');db.session.add(group);db.session.flush()
            server=Server.query.filter_by(user_id=current_user.id,name='Harbor PostgreSQL SSO').first()
            if server is None:
                server=Server(user_id=current_user.id,servergroup_id=group.id,name='Harbor PostgreSQL SSO',port=5432,save_password=0,use_ssh_tunnel=0,tunnel_authentication=0,shared=False,kerberos_conn=False)
                db.session.add(server)
            server.host='127.0.0.1';server.username=values['username'];server.maintenance_db='postgres' if admin_tool else values['databases'][0]
            # pgAdmin server mode resolves this value inside the current
            # user's storage directory before passing the absolute path to
            # libpq. Supplying an absolute path here makes pgAdmin prepend
            # that directory again, so the password file is never found.
            server.connection_params={'passfile':passfile.name,'connect_timeout':5,'sslmode':'prefer'}
            server.password=None;server.passexec_cmd=None;server.db_res='' if admin_tool else ','.join(values['databases']);server.db_res_type='databases'
            db.session.commit()
            sid=(request.view_args or {}).get('sid')
            if sid is not None and int(sid)!=server.id:abort(403)
