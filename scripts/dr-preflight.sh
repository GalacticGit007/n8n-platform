#!/usr/bin/env bash
# Read-only preflight checks. Never prints credential material.
set -Eeuo pipefail
IFS=$'\n\t'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0; WARN=0
log(){ printf '[dr-preflight] %s\n' "$*"; }
pass(){ log "PASS: $*"; }
warn(){ WARN=$((WARN+1)); log "WARN: $*" >&2; }
fail(){ FAIL=$((FAIL+1)); log "FAIL: $*" >&2; }
has(){ command -v "$1" >/dev/null 2>&1; }
# Baseline tools are required now. Kubernetes tools are warnings until the
# infrastructure-tool installation stage is added to bootstrap.
for c in git ssh curl aws docker jq sha256sum df; do
  if has "$c"; then pass "$c found"; else fail "$c missing"; fi
done
for c in kubectl kind helm; do
  if has "$c"; then pass "$c found"; else warn "$c missing; install before cluster-recovery stage"; fi
done
if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] && pass "Ubuntu: ${PRETTY_NAME:-unknown}" || warn "Expected Ubuntu; found ${PRETTY_NAME:-unknown}"
else fail "/etc/os-release missing"; fi
if has df; then
  free_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if [[ "${free_kb:-0}" -ge 10485760 ]]; then pass "At least 10 GiB free on /"; else warn "Less than 10 GiB free on /"; fi
fi
ip route show default 2>/dev/null | grep -q '^default' && pass "Default route exists" || fail "No default route"
getent hosts github.com >/dev/null 2>&1 && pass "github.com DNS resolves" || fail "github.com DNS resolution failed"
curl --connect-timeout 5 --max-time 15 -fsSI https://github.com >/dev/null && pass "GitHub HTTPS reachable" || fail "Cannot reach GitHub over HTTPS"
if [[ -d "$ROOT/.git" ]]; then
  pass "Git clone found at $ROOT"
  git -C "$ROOT" status --short || warn "git status failed"
  git -C "$ROOT" remote -v | sed -E 's#(https?://)[^/@]+:[^/@]+@#\1[REDACTED]@#g'
else fail "Run this script from inside the cloned repository"; fi
if [[ -r "$HOME/.ssh/n8n-dr-deploy" ]]; then
  pass "Deploy-key file exists (contents hidden)"
else warn "Deploy key not found at ~/.ssh/n8n-dr-deploy"; fi
if has ssh && [[ -r "$HOME/.ssh/n8n-dr-deploy" ]]; then
  ssh_out="$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 -i "$HOME/.ssh/n8n-dr-deploy" -o IdentitiesOnly=yes git@github.com 2>&1 || true)"
  if grep -qiE 'successfully authenticated|shell access is not provided' <<<"$ssh_out"; then pass "GitHub SSH authentication confirmed"; else warn "GitHub SSH auth not confirmed; check deploy key and known_hosts"; fi
fi
if has aws; then
  ident="$(aws sts get-caller-identity --output json 2>/dev/null || true)"
  if [[ -n "$ident" ]] && jq -e '.Account and .Arn' >/dev/null 2>&1 <<<"$ident"; then
    pass "AWS STS authenticated: account=$(jq -r .Account <<<"$ident") arn=$(jq -r .Arn <<<"$ident")"
  else fail "AWS STS authentication failed/no credential provider"; fi
  region="${AWS_REGION:-ap-south-1}"
  bucket="${DR_S3_BUCKET:-n8n-dr-backups-20261023-8f039112}"
  prefix="${DR_S3_PREFIX:-cnpg/n8n-db-cluster/}"
  if aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --max-items 1 --region "$region" >/dev/null 2>&1; then
    pass "S3 list access works for s3://$bucket/$prefix ($region)"
  else fail "Cannot list expected S3 prefix; check identity, IAM policy, bucket and region"; fi
else fail "AWS CLI missing"; fi
log "Summary: $FAIL failure(s), $WARN warning(s)"
if (( FAIL > 0 )); then log "FAILED. No recovery action performed."; exit 1; fi
log "PASSED. This does not prove the backup/WAL chain is restorable."
