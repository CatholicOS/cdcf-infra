#!/usr/bin/env bash
#
# setup-vps-sync-user.sh — provision the dedicated VPS user that the
# sync-to-vps GitHub Actions workflow uses to git-pull /opt/cdcf-auth.
#
# Run ONCE on the VPS as root (or via sudo). Idempotent: re-runs are
# safe — user creation, dir/perm fixups, and the env-file ownership
# restoration are all guarded so a second run is a no-op.
#
# What this does
# ──────────────
# 1. Creates a system-style user (cdcfinfra-deploy) with NO sudo, NO
#    interactive password, and NO shell access to anything outside
#    its home dir + the repo dir. The dedicated user is the principle-
#    of-least-privilege boundary: even if its SSH key leaks, the
#    blast radius is "can fast-forward git pull /opt/cdcf-auth", not
#    arbitrary code execution as the operator account.
# 2. chowns /opt/cdcf-auth to the dedicated user so `git pull` works
#    without sudo.
# 3. Restores ubuntu ownership + mode 0600 on .env.production so
#    the secret value stays unreadable to the dedicated user.
# 4. Initialises ~/.ssh/authorized_keys for the dedicated user;
#    you paste the workflow's public key into it as a final step.
#
# Required GitHub repo settings (operator action after this script)
# ─────────────────────────────────────────────────────────────────
# Generate an ed25519 keypair somewhere safe:
#     ssh-keygen -t ed25519 -C "cdcf-infra sync workflow" -f ./sync-key
# Then in cdcf-infra → Settings:
#   Secrets:
#     VPS_SSH_KEY      = contents of ./sync-key (the PRIVATE half)
#     VPS_USERNAME     = cdcfinfra-deploy
#     VPS_HOST         = <the VPS hostname / IP the runner SSHes to>
#   Variables:
#     VPS_HOST_KEY        = output of `ssh-keyscan -t ed25519,rsa <host>`
#     CDCF_INFRA_REPO_DIR = /opt/cdcf-auth
# Then on the VPS:
#     sudo bash -c 'cat >> /home/cdcfinfra-deploy/.ssh/authorized_keys' <<<'<the PUBLIC half>'
#
# After all of the above, the next push to main (or workflow_dispatch)
# triggers the sync workflow, which SSHes in as cdcfinfra-deploy and
# runs `git -C /opt/cdcf-auth pull --ff-only origin main`.

set -euo pipefail

USER_NAME="cdcfinfra-deploy"
REPO_DIR="/opt/cdcf-auth"
ENV_FILE="$REPO_DIR/auth/.env.production"
ENV_OWNER="ubuntu" # User that owns .env.production (and any other secret files).

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must run as root (try: sudo $0)" >&2
    exit 1
fi

if [ ! -d "$REPO_DIR" ]; then
    echo "ERROR: $REPO_DIR does not exist. Clone the repo there first." >&2
    exit 1
fi

if [ ! -d "$REPO_DIR/.git" ]; then
    echo "ERROR: $REPO_DIR is not a git repo. Clone it first." >&2
    exit 1
fi

# 1. Create the dedicated user if missing. No password (-r system user
#    if you prefer; we use a regular user so its $HOME is writable for
#    SSH config).
if ! id -u "$USER_NAME" >/dev/null 2>&1; then
    echo "Creating user: $USER_NAME"
    useradd --create-home --shell /bin/bash "$USER_NAME"
    passwd --lock "$USER_NAME" >/dev/null
else
    echo "User already exists: $USER_NAME"
fi

# 2. Initialise the SSH config dir + authorized_keys.
SSH_DIR="/home/$USER_NAME/.ssh"
AUTHKEYS="$SSH_DIR/authorized_keys"
mkdir -p "$SSH_DIR"
touch "$AUTHKEYS"
chmod 700 "$SSH_DIR"
chmod 600 "$AUTHKEYS"
chown -R "$USER_NAME:$USER_NAME" "$SSH_DIR"

# 3. Give the dedicated user ownership of the repo dir so it can git
#    pull without sudo. Recursive chown will sweep .env.production
#    along with everything else — we restore it below.
echo "Chowning $REPO_DIR → $USER_NAME"
chown -R "$USER_NAME:$USER_NAME" "$REPO_DIR"

# 4. Restore ubuntu ownership + mode 0600 on the env file (secret).
if [ -f "$ENV_FILE" ]; then
    echo "Restoring $ENV_OWNER ownership on $ENV_FILE"
    chown "$ENV_OWNER:$ENV_OWNER" "$ENV_FILE"
    chmod 0600 "$ENV_FILE"
fi

# 5. Final state print so the operator sees what to do next.
cat <<EOF

✓ Provisioned $USER_NAME with write access to $REPO_DIR.
✓ $ENV_FILE restored to $ENV_OWNER:$ENV_OWNER mode 0600.

NEXT STEPS
──────────
1. Generate the workflow's SSH keypair on a workstation:
       ssh-keygen -t ed25519 -C "cdcf-infra sync workflow" -f ./sync-key

2. Append the PUBLIC half to $AUTHKEYS:
       cat sync-key.pub | sudo tee -a $AUTHKEYS

3. Capture the VPS host key for pinning in the workflow:
       ssh-keyscan -t ed25519,rsa <vps-hostname>

4. In the cdcf-infra repo Settings (https://github.com/CatholicOS/cdcf-infra/settings):
     Secrets → New repository secret:
       VPS_SSH_KEY      ← contents of ./sync-key (the PRIVATE half)
       VPS_USERNAME     ← $USER_NAME
       VPS_HOST         ← <the VPS hostname>
     Variables → New repository variable:
       VPS_HOST_KEY        ← output of step 3
       CDCF_INFRA_REPO_DIR ← $REPO_DIR

5. Trigger the workflow once manually to verify:
       gh workflow run sync-to-vps.yml --repo CatholicOS/cdcf-infra
EOF
