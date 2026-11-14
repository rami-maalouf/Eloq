#!/usr/bin/env python3
# puts the routes in /etc/traefik-routes.d/*.yml back into the shared traefik provider file.
# the matrix playbook (multiplexer repo) rewrites that file from its own inventory, which
# drops every route it does not know. this runs after each rewrite, through
# traefik-routes-guard.path, and writes only when something is missing, so it cannot loop.
import glob, os, sys, tempfile, yaml

PROVIDER = '/matrix/traefik/config/provider.yml'
FRAGMENTS = '/etc/traefik-routes.d/*.yml'

def merge(base, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base

def main():
    with open(PROVIDER) as f:
        current = yaml.safe_load(f) or {}
    wanted = yaml.safe_load(yaml.safe_dump(current))
    for path in sorted(glob.glob(FRAGMENTS)):
        with open(path) as f:
            merge(wanted, yaml.safe_load(f) or {})
    if wanted == current:
        print('routes present')
        return
    st = os.stat(PROVIDER)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(PROVIDER), prefix='.provider-')
    with os.fdopen(fd, 'w') as f:
        yaml.safe_dump(wanted, f, sort_keys=True)
    os.chown(tmp, st.st_uid, st.st_gid)
    os.chmod(tmp, st.st_mode & 0o777)
    os.replace(tmp, PROVIDER)
    added = sorted(set(wanted.get('http', {}).get('routers', {})) - set(current.get('http', {}).get('routers', {})))
    print('restored routers:', ', '.join(added) or '(changed fields)')

if __name__ == '__main__':
    sys.exit(main())
