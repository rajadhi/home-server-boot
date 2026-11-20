#!/usr/bin/env python3
"""A user-owned pilot: Git supplies one text blob, never executable code."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import subprocess
import tempfile
import time


class Pilot:
    def __init__(self, home=None):
        self.home = Path.home() if home is None else Path(home)
        self.config = self.home / '.config/home-server-pilot/source.json'
        self.state = self.home / '.local/state/home-server-pilot'
        self.data = self.home / '.local/share/home-server-pilot'
        self.message = self.state / 'message'
        self.status_file = self.state / 'status.json'

    def directory(self, path):
        if path.is_symlink():
            raise ValueError('Unexpected directory symlink: '+str(path))
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
        if path.stat().st_uid != os.geteuid():
            raise ValueError('Directory belongs to another account')
        path.chmod(0o700)

    def write(self, path, content, mode=0o600):
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
            name = temporary.name
            temporary.write(content)
            os.fchmod(temporary.fileno(), mode)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(name,path)

    def status(self):
        result = json.loads(self.status_file.read_text()) if self.status_file.exists() else {}
        result['paused'] = (self.state / 'paused').exists()
        last = result.get('last_success')
        result['verified_age_seconds'] = max(0,time.time()-last['time']) if last else None
        return result

    def git(self, config, *args):
        environment = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_COUNT='0')
        for key in list(environment):
            if key.startswith('GIT_') and key not in ['GIT_TERMINAL_PROMPT','GIT_CONFIG_NOSYSTEM','GIT_CONFIG_GLOBAL','GIT_CONFIG_COUNT']:
                del environment[key]
        if config.get('test_mode'):
            if not Path('/etc/home-server-test-guest').is_file():
                raise ValueError('Local remotes require a marked disposable guest')
            protocol = 'always'
            if not re.fullmatch(r'file:///var/tmp/[A-Za-z0-9/_.-]+',config['repo']):
                raise ValueError('Test remote must be a guest-owned /var/tmp path')
        else:
            protocol = 'never'
            if not re.fullmatch(r'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git',config['repo']):
                raise ValueError('Pilot requires a GitHub SSH repository URL')
            ssh = ['ssh','-F','/dev/null','-i',str(self.data / 'ssh/deploy_ed25519'),'-o','IdentityAgent=none','-o','IdentitiesOnly=yes','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','UserKnownHostsFile='+str(self.data / 'ssh/known_hosts'),'-o','ConnectTimeout=10']
            environment['GIT_SSH_COMMAND'] = ' '.join(shlex.quote(x) for x in ssh)
        command = ['git','--no-pager','-c','core.hooksPath=/dev/null','-c','protocol.file.allow='+protocol,'--git-dir='+str(self.data / 'repository.git'),*args]
        return subprocess.run(command,env=environment,check=True,capture_output=True,timeout=25).stdout

    def apply(self, config, previous):
        branch = config['branch']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9/_.-]*',branch) or '..' in branch:
            raise ValueError('Invalid branch')
        if not (self.data / 'repository.git').exists():
            self.git(config,'init','--bare')
        self.git(config,'fetch','--no-tags','--depth=1',config['repo'],'refs/heads/'+branch)
        revision = self.git(config,'rev-parse','--verify','FETCH_HEAD^{commit}').decode().strip()
        if not re.fullmatch(r'(?:[0-9a-f]{40}|[0-9a-f]{64})',revision):
            raise ValueError('Invalid fetched commit')
        content = self.git(config,'show',revision+':pilot/message.txt')
        if len(content) > 65536 or b'\x00' in content:
            raise ValueError('Pilot message must be text under 64 KiB')
        content.decode('utf-8')
        changed = self.message.is_symlink() or not self.message.is_file()
        if not changed:
            metadata = self.message.stat()
            changed = self.message.read_bytes() != content or stat.S_IMODE(metadata.st_mode) != 0o644 or metadata.st_uid != os.geteuid()
        if changed:
            self.write(self.message,content,0o644)
        observed = self.message.stat()
        if self.message.is_symlink() or self.message.read_bytes() != content or stat.S_IMODE(observed.st_mode) != 0o644 or observed.st_uid != os.geteuid():
            raise ValueError('Independent file verification failed')
        now = time.time()
        result = dict(previous)
        result.pop('verified_age_seconds',None)
        result['last_success'] = {'revision':revision,'time':now,'sha256':hashlib.sha256(content).hexdigest()}
        if changed:
            result['last_apply'] = {'revision':revision,'time':now}
        result['attempt'] = {'status':'passed','revision':revision,'changed':changed,'finished':now}
        return result

    def run(self):
        self.directory(self.state)
        self.directory(self.data)
        with (self.state / 'lock').open('a') as lock:
            try:
                fcntl.flock(lock,fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(json.dumps({'status':'busy'}))
                return 75
            previous = self.status()
            if previous['paused']:
                print(json.dumps({'status':'paused','last_success':previous.get('last_success')}))
                return 0
            active = dict(previous)
            active.pop('verified_age_seconds',None)
            active['attempt'] = {'status':'running','started':time.time()}
            self.write(self.status_file,json.dumps(active,indent=2).encode())
            try:
                config = json.loads(self.config.read_text())
                result = self.apply(config,previous)
            except Exception as error:
                active['attempt'].update(status='failed',finished=time.time(),error=type(error).__name__+': '+str(error)[:300])
                self.write(self.status_file,json.dumps(active,indent=2).encode())
                print(json.dumps(active['attempt']))
                return 1
            self.write(self.status_file,json.dumps(result,indent=2).encode())
            print(json.dumps(result['attempt']))
            return 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command',choices=['run','status','pause','resume'])
    args = parser.parse_args()
    pilot = Pilot()
    if args.command == 'run':
        return pilot.run()
    if args.command == 'status':
        print(json.dumps(pilot.status(),indent=2))
    elif args.command == 'pause':
        pilot.directory(pilot.state)
        pilot.write(pilot.state / 'paused',b'paused\n')
        print('Paused; an active check may finish.')
    else:
        (pilot.state / 'paused').unlink(missing_ok=True)
        print('Resumed; the next timer checks Git.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
