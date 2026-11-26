#!/usr/bin/env bash
# Bootstrap: validate, install git/Ansible/gh if absent, authenticate/download the pinned source, start Ansible.
set -euo pipefail
[ "${HS_MODE:-hello}" = hello ] || { echo 'Only the Ansible-managed dashboard milestone is supported.' >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo 'Run through the generated attended ssh -t command.' >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 26.04 ] || { echo 'Requires Ubuntu 26.04.' >&2; exit 1; }
if [ "${HS_ATTENDED_SSH:-0}" = 1 ]; then
  [ -t 0 ] && [ -t 1 ] || { echo 'Attended SSH deployment requires an interactive terminal.' >&2; exit 1; }
else
  [ -z "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ] || { echo 'Use the generated attended ssh -t deployment command.' >&2; exit 1; }
fi
ADMIN=${SUDO_USER:-}
[ -n "$ADMIN" ] && [ "$ADMIN" != root ] || { echo 'Run sudo as your normal Ubuntu user.' >&2; exit 1; }
# A fresh Ubuntu host may lack the runtime: install only these Ubuntu archive packages, then verify them.
missing=()
command -v git >/dev/null || missing+=(git)
command -v ansible-playbook >/dev/null || missing+=(ansible)
command -v gh >/dev/null || missing+=(gh)
if [ "${#missing[@]}" -gt 0 ]; then
  printf 'Installing bootstrap prerequisites: %s\n' "${missing[*]}"
  DEBIAN_FRONTEND=noninteractive timeout --foreground -k 15 600 apt-get update -q
  DEBIAN_FRONTEND=noninteractive timeout --foreground -k 15 600 apt-get install -y -q "${missing[@]}"
fi
for prerequisite in ansible-playbook git gh; do
  command -v "$prerequisite" >/dev/null || { echo "Missing prerequisite after install: $prerequisite." >&2; exit 1; }
done
HS_HELLO_REF=${HS_HELLO_REF:-a873159ca1fe4c243eaf276ea2df2f77ce744ba8}
[[ "$HS_HELLO_REF" =~ ^[0-9a-f]{40}$ ]] || { echo 'HS_HELLO_REF must be a full Git commit.' >&2; exit 1; }
if [ -n "${HS_TEST_BUNDLE:-}" ]; then
  if [ ! -f /etc/home-server-test-vm ] || ! systemd-detect-virt --quiet; then
    echo 'Test bundles require a marked VM.' >&2; exit 1
  fi
  [ -f "$HS_TEST_BUNDLE" ] || { echo 'Missing test bundle.' >&2; exit 1; }
elif [ ! -f /etc/home-server-github/id_ed25519 ]; then
  command -v gh >/dev/null || { echo 'GitHub CLI must already be available for private source authentication.' >&2; exit 1; }
  if ! sudo -u "$ADMIN" -H gh auth status --hostname github.com >/dev/null 2>&1; then
    sudo -u "$ADMIN" -H gh auth login --hostname github.com --git-protocol https --web
  fi
fi
# This deferred helper retrieves the owner's token without putting it on a command line.
# shellcheck disable=SC2016
HELPER='!f() { echo username=x-access-token; echo "password=$(sudo -u '"$ADMIN"' -H gh auth token)"; }; f'
source_git() {
  if [ -z "${HS_TEST_BUNDLE:-}" ] && [ -f /etc/home-server-github/id_ed25519 ]; then
    GIT_SSH_COMMAND='/usr/bin/ssh -i /etc/home-server-github/id_ed25519 -oIdentitiesOnly=yes -oBatchMode=yes -oIdentityAgent=none -oStrictHostKeyChecking=yes -oUserKnownHostsFile=/etc/home-server-github/known_hosts -oGlobalKnownHostsFile=/dev/null' \
      timeout --foreground -k 10 180 git -c credential.helper= \
      -c url.git@github.com:rajadhi/home-server.git.insteadOf=https://github.com/rajadhi/home-server.git "$@"
  else
    timeout --foreground -k 10 180 git -c credential.helper= -c "credential.helper=$HELPER" "$@"
  fi
}
SOURCE=/opt/home-server-hello/source
REPOSITORY=${HS_TEST_BUNDLE:-https://github.com/rajadhi/home-server.git}
printf 'Downloading tested configuration %s\n' "$HS_HELLO_REF"
if [ ! -d "$SOURCE/.git" ]; then
  source_git clone --no-checkout "$REPOSITORY" "$SOURCE"
fi
if [ -n "${HS_TEST_BUNDLE:-}" ]; then
  source_git -C "$SOURCE" fetch "$REPOSITORY" HEAD
else
  source_git -C "$SOURCE" fetch origin "$HS_HELLO_REF"
fi
source_git -C "$SOURCE" checkout --detach "$HS_HELLO_REF"
[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$HS_HELLO_REF" ]
export ANSIBLE_CONFIG="$SOURCE/ansible/hello.cfg"
export ANSIBLE_COLLECTIONS_PATH=/opt/home-server-hello/collections
export ANSIBLE_LOG_PATH=/var/log/home-server-hello.log
export HS_APPLY_REVISION="$HS_HELLO_REF"
EXTRA=()
if [ -n "${HS_HELLO_LAN:-}" ]; then
  EXTRA=(-e "hello_world_lan=$HS_HELLO_LAN")
fi
printf 'Starting Ansible: controller prerequisites and pinned collections\n'
timeout --foreground -k 15 600 ansible-playbook -i localhost, -c local "$SOURCE/ansible/controller.yml"
printf 'Starting Ansible: dashboard and host configuration\n'
exec timeout --foreground -k 15 2400 ansible-playbook -i localhost, -c local "$SOURCE/ansible/hello-world.yml" "${EXTRA[@]}"
