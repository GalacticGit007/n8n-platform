#!/usr/bin/env bash
# Initial Ubuntu DR bootstrap. Does not create a cluster or restore data.
set -Eeuo pipefail
IFS=$'\n\t'
REPO_URL="${DR_REPO_SSH_URL:-git@github.com:GalacticGit007/n8n-platform.git}"
DR_ROOT="${DR_ROOT:-$HOME/dr}"
REPO_DIR="${DR_REPO_DIR:-$DR_ROOT/n8n-platform}"
log(){ printf '[dr-bootstrap] %s\n' "$*"; }
die(){ log "ERROR: $*" >&2; exit 1; }
command -v sudo >/dev/null || die "sudo is required"
[[ "$(id -u)" -ne 0 ]] || die "Run as your normal user, not root"
[[ -r /etc/os-release ]] || die "Cannot identify OS"
. /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "Ubuntu only; found ${ID:-unknown}"
sudo -v
log "Installing baseline packages from configured Ubuntu APT repositories"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  ca-certificates curl git openssh-client gnupg jq unzip tar gzip awscli docker.io
sudo systemctl enable --now docker
getent hosts github.com >/dev/null || die "DNS lookup for github.com failed"
[[ -r "$HOME/.ssh/n8n-dr-deploy" ]] || die "Missing $HOME/.ssh/n8n-dr-deploy; provision private key securely first"
chmod 700 "$HOME/.ssh"
chmod 600 "$HOME/.ssh/n8n-dr-deploy"
mkdir -p "$DR_ROOT"
if [[ -d "$REPO_DIR/.git" ]]; then
  log "Repository already exists; not overwriting or pulling local changes: $REPO_DIR"
  git -C "$REPO_DIR" status --short
else
  log "Cloning $REPO_URL"
  GIT_SSH_COMMAND="ssh -i $HOME/.ssh/n8n-dr-deploy -o IdentitiesOnly=yes -o BatchMode=yes" \
    git clone "$REPO_URL" "$REPO_DIR"
fi
log "Bootstrap complete. No cluster was created and no data was restored."
log "Next: cd '$REPO_DIR' && scripts/dr-preflight.sh"
log "Use sudo docker until Docker group permissions are configured in a new login session."
