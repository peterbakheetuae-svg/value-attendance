#!/usr/bin/env bash
# Copies a staged Windows update (installer + latest.json + release.txt) to Hostinger and runs remote-deploy-windows.sh,
# which writes ONLY into public_html/valunivo/windows/. Host keys are pinned (no trust-on-first-use).
#   ssh_deploy_windows.sh STAGE_DIR     (env: SSH_HOST SSH_PORT SSH_USER and SSH_KEY or SSH_PASS)
set -euo pipefail
STAGE=$1
HERE=$(cd "$(dirname "$0")" && pwd)
[ -n "${SSH_KEY:-}" ] || [ -n "${SSH_PASS:-}" ] || { echo "::error::Hostinger secret missing"; exit 1; }
for f in "$STAGE"/*; do
  case "$(basename "$f")" in VALUNIVO-Setup-*.exe|latest.json|release.txt) ;; *) echo "::error::unexpected file: $f"; exit 1;; esac
done
mkdir -p ~/.ssh && chmod 700 ~/.ssh
cat > ~/.ssh/known_hosts <<'KH'
[82.198.227.7]:65002 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINIEVbKu9K7AVrGNwujYEUbrw0wvECMboXFOKfpiiw3h
[82.198.227.7]:65002 ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBCHeIP4sUl5WiCE5CU68sEpg0WFGfq/jyVGW0RqVzi3v56HYIJhINFOZvD3XxttLN/k7t2ZEjA52H73cegg6QGY=
KH
O="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=$HOME/.ssh/known_hosts"
if [ -n "${SSH_KEY:-}" ]; then
  trap 'rm -f "$HOME/.ssh/deploy"' EXIT
  printf '%s\n' "$SSH_KEY" > ~/.ssh/deploy && chmod 600 ~/.ssh/deploy
  SCP="scp $O -P $SSH_PORT -i $HOME/.ssh/deploy"; SSH="ssh $O -p $SSH_PORT -i $HOME/.ssh/deploy"
else
  sudo apt-get -qq update >/dev/null && sudo apt-get -qq install -y sshpass >/dev/null; export SSHPASS="$SSH_PASS"
  SCP="sshpass -e scp $O -P $SSH_PORT"; SSH="sshpass -e ssh $O -p $SSH_PORT"
fi
$SSH "$SSH_USER@$SSH_HOST" 'rm -rf ~/va-win-staging && mkdir -p ~/va-win-staging'
$SCP "$STAGE"/* "$SSH_USER@$SSH_HOST:va-win-staging/"
$SSH "$SSH_USER@$SSH_HOST" 'bash -s' < "$HERE/../../deploy/hostinger/remote-deploy-windows.sh"
