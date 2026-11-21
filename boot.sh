#!/usr/bin/env bash
# Default milestone: Ansible runs on Ubuntu. Use HS_MODE=full for the legacy rebuild.
if [ "${HS_MODE:-hello}" = hello ]; then
  set -euo pipefail
  [ "$(id -u)" -eq 0 ] || { echo 'Run with sudo on Ubuntu through the generated ssh -t command.' >&2; exit 1; }
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] || { echo 'Requires Ubuntu 26.04.' >&2; exit 1; }
  # The owner authorises attended SSH for this milestone. Never infer attendance
  # from sudo stripping SSH_* variables; the generated command sets an explicit marker.
  if [ "${HS_ATTENDED_SSH:-0}" = 1 ]; then
    [ -t 0 ] && [ -t 1 ] || { echo 'Attended SSH deployment requires an interactive terminal.' >&2; exit 1; }
  else
    [ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ] || { echo 'Use the generated attended ssh -t deployment command.' >&2; exit 1; }
  fi
  ADMIN=${SUDO_USER:-}
  [ -n "$ADMIN" ] && [ "$ADMIN" != root ] || { echo 'Run sudo as your normal Ubuntu user.' >&2; exit 1; }
  HS_HELLO_REF=${HS_HELLO_REF:-1032155ab540cc3003ea6c0356d2a47d00e50fc3}
  [[ "$HS_HELLO_REF" =~ ^[0-9a-f]{40}$ ]] || { echo 'HS_HELLO_REF must be a full Git commit.' >&2; exit 1; }
  install -d -m 0755 /opt/home-server-hello
  exec 9>/run/lock/home-server-hello.lock
  flock -n 9 || { echo 'Another hello bootstrap is running.' >&2; exit 1; }
  exec > >(tee -a /var/log/home-server-hello.log) 2>&1
  printf 'Hello bootstrap: %s, configuration %s\n' "$(date -Is)" "$HS_HELLO_REF"
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  timeout --foreground -k 10 300 apt-get update
  timeout --foreground -k 10 600 apt-get install -y ansible git gh ca-certificates
  if [ -n "${HS_TEST_BUNDLE:-}" ]; then
    if [ ! -f /etc/home-server-test-vm ] || ! systemd-detect-virt --quiet; then
      echo "Test bundles require a marked disposable VM." >&2; exit 1
    fi
    [ -f "$HS_TEST_BUNDLE" ] || { echo "Missing test bundle." >&2; exit 1; }
  elif ! sudo -u "$ADMIN" -H gh auth status --hostname github.com >/dev/null 2>&1; then
    printf '\nAuthenticate the private configuration repo using the device code below.\n'
    sudo -u "$ADMIN" -H gh auth login --hostname github.com --git-protocol https --web
  fi
  # Git evaluates this credential helper later; keep the substitution deferred.
  # shellcheck disable=SC2016
  HELPER='!f() { echo username=x-access-token; echo "password=$(sudo -u '"$ADMIN"' -H gh auth token)"; }; f'
  hello_git() { timeout --foreground -k 10 180 git -c credential.helper= -c "credential.helper=$HELPER" "$@"; }
  REPOSITORY=${HS_TEST_BUNDLE:-https://github.com/rajadhi/home-server.git}
  SOURCE=/opt/home-server-hello/source
  if [ ! -d "$SOURCE/.git" ]; then
    hello_git clone --no-checkout "$REPOSITORY" "$SOURCE"
  fi
  if [ -n "${HS_TEST_BUNDLE:-}" ]; then
    hello_git -C "$SOURCE" fetch "$REPOSITORY" HEAD
  else
    hello_git -C "$SOURCE" fetch origin "$HS_HELLO_REF"
  fi
  git -C "$SOURCE" checkout --detach "$HS_HELLO_REF"
  test "$(git -C "$SOURCE" rev-parse HEAD)" = "$HS_HELLO_REF"
  export ANSIBLE_CONFIG="$SOURCE/ansible/hello.cfg" ANSIBLE_COLLECTIONS_PATH=/opt/home-server-hello/collections
  timeout --foreground -k 10 300 ansible-galaxy collection install -r "$SOURCE/ansible/hello-requirements.yml" -p "$ANSIBLE_COLLECTIONS_PATH"
  export HS_APPLY_REVISION="$HS_HELLO_REF"
  EXTRA=()
  if [ -n "${HS_HELLO_LAN:-}" ]; then
    LAN_JSON=$(python3 -c 'import ipaddress,json,os; print(json.dumps({"hello_world_lan": str(ipaddress.IPv4Network(os.environ["HS_HELLO_LAN"]))}))')
    EXTRA=(-e "$LAN_JSON")
  fi
  cd "$SOURCE/ansible"
  timeout --foreground -k 15 2400 ansible-playbook -i localhost, -c local hello-world.yml "${EXTRA[@]}"
  printf '\nReady: http://<ubuntu-ip>:17283/\nLog: /var/log/home-server-hello.log\n'
  exit 0
fi
[ "${HS_MODE:-}" = full ] || { echo 'HS_MODE must be hello or full.' >&2; exit 1; }

# home-server bootstrap: bare Ubuntu Server 26.x -> the whole server, from the private home-server repo.
# This is the ONLY imperative script; everything after it is declared in Ansible.
#
# At the physical console, logged in as the admin user, paste (the command is kept in the password manager):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/rajadhi/home-server-boot/<COMMIT>/boot.sh)"
#
# Asks everything up front (GitHub login, vault passphrase), then runs unattended. Log: /var/log/home-server-install.log
# Options (env): HS_REF=<branch|tag|commit> (default below), HS_VM=1 on a test VM (skips Mac hardware, VPN tunnel, logins).
set -euo pipefail

HS_REPO_URL=${HS_REPO_URL:-https://github.com/rajadhi/home-server.git}
HS_REF=${HS_REF:-66a283c5f4028a6da47db16c4b5223f499abb796}   # pinned: a rebuild must run this exact tested commit, not whatever main is later
HS_VM=${HS_VM:-0}
# Test-VM only (tests/vm-drill.sh): HS_SKIP_GH=1 clones HS_REPO_URL (a local git bundle) without a GitHub
# login; HS_VAULT_PASS_FILE gives the passphrase; HS_EXTRA_VARS is a JSON file of extra Ansible variables.
HS_SKIP_GH=${HS_SKIP_GH:-0}
HS_VAULT_PASS_FILE=${HS_VAULT_PASS_FILE:-}
HS_EXTRA_VARS=${HS_EXTRA_VARS:-}
ROOT_CHECKOUT=/opt/home-server
LOG=/var/log/home-server-install.log

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ask()  { local v; read -r -p "$1" v </dev/tty; printf '%s' "$v"; }

# --- 1. preflight -----------------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run with sudo"
ADMIN=${SUDO_USER:-}; [ -n "$ADMIN" ] && [ "$ADMIN" != root ] || die "run with sudo from the admin user's account"
ADMIN_HOME=$(getent passwd "$ADMIN" | cut -d: -f6)
# shellcheck source=/dev/null
. /etc/os-release
[ "$ID" = ubuntu ] && [ "${VERSION_ID%%.*}" = 26 ] || die "needs Ubuntu 26.x (found $PRETTY_NAME)"
[ -t 0 ] || [ -r /dev/tty ] || die "needs a terminal for the prompts"
REMOTE=false; [ -n "${SSH_CONNECTION:-}" ] && REMOTE=true
if [ "$REMOTE" = true ] && [ "$HS_VM" != 1 ]; then
  die "run this at the physical console, not over SSH (the network steps would cut you off)"
fi
timeout 20 curl -fsS -o /dev/null https://archive.ubuntu.com </dev/null || die "no internet (plug in the USB Ethernet adapter)"
exec > >(tee -a "$LOG") 2>&1
echo "home-server bootstrap $(date -Is)  ref=$HS_REF  vm=$HS_VM  admin=$ADMIN"

# --- 2. tools ---------------------------------------------------------------------------------------
say "Installing git, GitHub CLI and Ansible (Ubuntu packages)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
apt-get update -qq
apt-get install -y -qq git gh ansible curl ca-certificates >/dev/null

# --- 3. questions (all of them, now) ----------------------------------------------------------------
if [ "$HS_SKIP_GH" != 1 ]; then
  say "GitHub login (as $ADMIN). Open the link on your phone and enter the code shown."
  if ! sudo -u "$ADMIN" -H gh auth status --hostname github.com >/dev/null 2>&1; then
    sudo -u "$ADMIN" -H gh auth login --hostname github.com --git-protocol https --web
  fi
  sudo -u "$ADMIN" -H gh auth setup-git --hostname github.com
fi

say "Vault passphrase (unlocks every secret in the repo)"
install -d -m 0700 -o root -g root /etc/home-server
if [ -n "$HS_VAULT_PASS_FILE" ]; then
  install -m 0600 -o root -g root "$HS_VAULT_PASS_FILE" /etc/home-server/vault-pass
elif [ ! -s /etc/home-server/vault-pass ]; then
  read -r -s -p "Vault passphrase: " P </dev/tty; echo
  umask 077; printf '%s\n' "$P" > /etc/home-server/vault-pass; unset P
fi
chmod 0600 /etc/home-server/vault-pass

# --- 4. code ----------------------------------------------------------------------------------------
say "Downloading home-server ($HS_REF)"
# Git evaluates this credential helper later; keep the substitution deferred.
# shellcheck disable=SC2016
HELPER='!f() { echo username=x-access-token; echo "password=$(sudo -u '"$ADMIN"' -H gh auth token)"; }; f'
if [ "$HS_SKIP_GH" = 1 ]; then g() { git "$@"; }; else g() { git -c credential.helper= -c "credential.helper=$HELPER" "$@"; }; fi
[ -d "$ROOT_CHECKOUT/.git" ] || g clone --quiet "$HS_REPO_URL" "$ROOT_CHECKOUT"
g -C "$ROOT_CHECKOUT" fetch --quiet --prune origin
git -C "$ROOT_CHECKOUT" checkout --quiet --detach "origin/$HS_REF" 2>/dev/null || git -C "$ROOT_CHECKOUT" checkout --quiet --detach "$HS_REF"
chown -R root:root "$ROOT_CHECKOUT"
echo "commit: $(git -C "$ROOT_CHECKOUT" log -1 --format='%h %s')"
# The admin user's own working copy, for agents to make future changes in.
[ -d "$ADMIN_HOME/home-server/.git" ] || sudo -u "$ADMIN" -H git clone --quiet "$HS_REPO_URL" "$ADMIN_HOME/home-server"

ansible-vault view --vault-password-file /etc/home-server/vault-pass "$ROOT_CHECKOUT/ansible/vault/vault.yml" >/dev/null 2>&1 \
  || { rm -f /etc/home-server/vault-pass; die "wrong vault passphrase; run the command again"; }

# --- 5. everything else (Ansible) -------------------------------------------------------------------
say "Installing and configuring everything (30-60 minutes; no input needed)"
VM_ARGS=(); [ "$HS_VM" = 1 ] && VM_ARGS=(-e vm_mode=true -e allow_remote_net=true)
[ -n "$HS_EXTRA_VARS" ] && VM_ARGS+=(-e "@$HS_EXTRA_VARS")
cd "$ROOT_CHECKOUT/ansible"
ansible-playbook site.yml -e "remote_session=$REMOTE" "${VM_ARGS[@]}" </dev/null || die "Ansible failed; fix and run the same command again (it resumes safely)"

# --- 6. interactive finish --------------------------------------------------------------------------
if [ "$HS_VM" != 1 ]; then
  say "Tailscale login. Open the link shown and approve this machine."
  tailscale status >/dev/null 2>&1 || tailscale up --timeout=10m
  ansible-playbook site.yml --tags tailscale -e "remote_session=$REMOTE" </dev/null >/dev/null
fi

say "Second run: must report changed=0"
ansible-playbook site.yml -e "remote_session=$REMOTE" "${VM_ARGS[@]}" </dev/null | tee /tmp/home-server-second-run.txt | tail -4
if grep -qE 'changed=0 .*failed=0' /tmp/home-server-second-run.txt; then
  echo "IDEMPOTENT: OK"
else
  die "IDEMPOTENT: NOT OK (the second run changed something; see $LOG)"
fi

cat <<'TXT'

==> Done. Remaining manual steps (docs/manual-steps.md has the details):
  1. Log in to the CLIs as your user: claude, codex, gemini
  2. Register the Signal bot:   ~/openclaw/scripts/signal-register.sh start   (then verify; phone needed)
  3. OpenClaw web UI over Tailscale: sign in with the gateway token (docs/manual-steps.md)
  4. Jellyfin: open http://<server>:8096 and finish the setup wizard (create the admin user)
  5. Tailscale admin console: remove the old "home-server" device if it is still listed
  6. Reboot once (tests the clock/VPN start-up), then: sudo home-server-check  -> changed=0
TXT
