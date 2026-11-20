# Harmless-message pilot runner

The private configuration repository's `ansible/pilot.yml` installs these files into the existing user's home directory. This directory contains no bootstrap installer and is separate from the existing full-host `boot.sh`.

The runner fetches a selected branch and reads only `pilot/message.txt`. It never executes fetched repository code. It writes one user-owned message, records the verified commit and hash, honours pause, and repairs message contents and mode on the next check. The user timer polls once a minute while the user manager is running.

Commands after Ansible installation:

```sh
python3 ~/.local/lib/home-server-pilot/runner.py status
python3 ~/.local/lib/home-server-pilot/runner.py pause
python3 ~/.local/lib/home-server-pilot/runner.py resume
```

Git uses only the dedicated host-generated deploy key, with agent access and ambient SSH configuration disabled. Register its public half on the configuration repository with write access disabled. No personal GitHub credential is copied to the server.

`github_known_hosts` contains GitHub's ED25519 host key retrieved from its official HTTPS metadata endpoint, https://api.github.com/meta, on 20 November 2026. Fingerprint: `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`.

This is an unprivileged learning milestone. It provides no OS package, firewall, Docker, privileged deployment or complete release-one assurance. Boot/disconnected operation requires an active user manager; check lingering separately.
