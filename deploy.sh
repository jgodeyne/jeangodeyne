#!/usr/bin/env bash
set -euo pipefail

# deploy.sh - Rsync the jeangodeyne site to your NAS (hardcoded)
# Hardcoded defaults:
#   REMOTE_HOST=jego-nas
#   REMOTE_USER=jean
#   REMOTE_PATH=/docker/webserver/html/jeangodeyne
# Behavior:
#   - The script performs a REAL deploy by default. Use `--dry-run` to test without changing remote files.
#   - If `ssh_password.gpg` exists in the script directory, the script will attempt to decrypt it and pass
#     the SSH password to rsync/ssh using `sshpass`. This requires `gpg` (for decryption) and `sshpass`.
#     If decryption or `sshpass` is not available, the script falls back to normal SSH (keys or interactive login).
#   - The script will attempt to set ownership on the remote to UID:GID 33:33 (www-data) via sudo.
#   - Change the hardcoded variables below if you need a different target or behavior.

# Hardcoded deployment config (with optional CLI flag for dry-run)
REMOTE_HOST="jego-nas"
REMOTE_USER="jean"
REMOTE_PATH="/docker/webserver/html/jeangodeyne"
SSH_PORT=22
# Base rsync options; we'll add either --update (default) or --inplace when --force is used
BASE_RSYNC_OPTS='-rlvz --no-perms --no-owner --no-group --delete --exclude=.git --exclude=.gitignore --exclude=node_modules --exclude=.env --exclude=docker-compose.yml --exclude=encrypt_password.sh --exclude=ssh_password.gpg --exclude=.vscode --exclude=deploy.sh --exclude=README.md'
RSYNC_OPTS="$BASE_RSYNC_OPTS --update"
CHOWN_ON_REMOTE='33:33'
# By default perform a real deploy. Use --dry-run to perform a dry run.
DRY_RUN=0
FORCE=0
FIX_PERMS=1

# Optional argument parsing:
#   --dry-run   Run as a dry run (no files will be changed)
#   --fix-perms Fix ownership/permissions on remote before and after deploy
#   --force     Force overwrite (remove --update and write files in-place)
#   -h|--help   Show brief usage
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1; shift ;;
    --fix-perms)
      FIX_PERMS=1; shift ;;
    --force)
      FORCE=1; shift ;;
    -h|--help)
      echo "Usage: ./deploy.sh [--dry-run] [--fix-perms] [--force]"; exit 0 ;;
    *)
      echo "Unknown arg: $1"; echo "Usage: ./deploy.sh [--dry-run] [--fix-perms] [--force]"; exit 2 ;;
  esac
done

if [[ $DRY_RUN -eq 1 ]]; then
  RSYNC_OPTS="$RSYNC_OPTS --dry-run"
  echo "*** DRY RUN: no files will be changed on the remote (use no flag to run real deploy) ***"
fi

# Adjust rsync options when forcing overwrite
if [[ $FORCE -eq 1 ]]; then
  # Remove --update and add --inplace to ensure destination is overwritten
  RSYNC_OPTS="$BASE_RSYNC_OPTS --inplace"
fi

echo "Deploying to: ${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}"

# If an encrypted password is available, try to use it with sshpass
SSH_PASSWORD_FILE="ssh_password.gpg"
USE_SSHPASS=0
if [ -f "$SSH_PASSWORD_FILE" ]; then
  if ! command -v gpg >/dev/null 2>&1; then
    echo "ssh_password.gpg found but 'gpg' is not installed. Install gpg or remove the file." >&2
  else
    echo "Found $SSH_PASSWORD_FILE — attempting to decrypt (you will be prompted for GPG passphrase if needed)"
    set +x
    SSH_PASSWORD=$(gpg --quiet --decrypt "$SSH_PASSWORD_FILE" 2>/dev/null || true)
    set -x
    if [ -n "${SSH_PASSWORD}" ]; then
      if command -v sshpass >/dev/null 2>&1; then
        USE_SSHPASS=1
      else
        echo "Decrypted password available but 'sshpass' is not installed; please install sshpass to use password-based SSH." >&2
      fi
    else
      echo "Could not decrypt $SSH_PASSWORD_FILE (wrong passphrase or other error)." >&2
    fi
  fi
fi

# If requested, pre-fix remote permissions before rsync to avoid mkstemp permission errors
if [[ $FIX_PERMS -eq 1 ]]; then
  echo "Pre-fixing ownership and permissions on remote before rsync (requires sudo on ${REMOTE_HOST})..."
  REMOTE_SSH_PATH="/volume1${REMOTE_PATH}"
  if [[ $USE_SSHPASS -eq 1 ]]; then
    sshpass -p "$SSH_PASSWORD" ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
      "echo '$SSH_PASSWORD' | sudo -S chown -R ${REMOTE_USER} '${REMOTE_SSH_PATH}' && echo '$SSH_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type d -exec chmod 775 {} \; && echo '$SSH_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type f -exec chmod 664 {} \;"
  else
    if [[ -z "${SUDO_PASSWORD:-}" ]]; then
      read -s -p "Enter sudo password for ${REMOTE_USER}@${REMOTE_HOST}: " SUDO_PASSWORD; echo
    fi
    ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
      "echo '$SUDO_PASSWORD' | sudo -S chown -R ${REMOTE_USER} '${REMOTE_SSH_PATH}' && echo '$SUDO_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type d -exec chmod 775 {} \; && echo '$SUDO_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type f -exec chmod 664 {} \;"
  fi
  echo "Pre-fix completed. Proceeding with rsync..."
fi

# Build rsync command (temporarily disable exit-on-error to handle rsync exit codes)
set +e
RSYNC_EXIT=0
if [[ $USE_SSHPASS -eq 1 ]]; then
  echo "Using sshpass to supply SSH password for rsync (decrypted from $SSH_PASSWORD_FILE)."
  sshpass -p "$SSH_PASSWORD" rsync -e "ssh -p ${SSH_PORT}" ${RSYNC_OPTS} ./ ${REMOTE_USER}@${REMOTE_HOST}:"${REMOTE_PATH}" 2>&1 | grep -v "failed to chown"
  RSYNC_EXIT=${PIPESTATUS[0]}
else
  rsync -e "ssh -p ${SSH_PORT}" ${RSYNC_OPTS} ./ ${REMOTE_USER}@${REMOTE_HOST}:"${REMOTE_PATH}" 2>&1 | grep -v "failed to chown"
  RSYNC_EXIT=${PIPESTATUS[0]}
fi
set -e

# Check rsync exit code (allow minor errors if we're fixing perms afterward)
if [[ $RSYNC_EXIT -ne 0 ]]; then
  # Exit codes: 0=success, 23=partial transfer, 24=partial transfer (vanished files)
  # When using --fix-perms, ignore chown/permission errors (exit codes 1, 23, 24)
  if [[ $FIX_PERMS -eq 1 ]] && [[ $RSYNC_EXIT -eq 1 || $RSYNC_EXIT -eq 23 || $RSYNC_EXIT -eq 24 ]]; then
    echo "rsync reported partial success (exit $RSYNC_EXIT) — will fix permissions next"
  else
    echo "rsync failed with exit code $RSYNC_EXIT" >&2
    exit $RSYNC_EXIT
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run complete. Review output above."
  exit 0
fi

echo "Deploy finished."

# Fix permissions on remote if requested
if [[ $FIX_PERMS -eq 1 ]]; then
  echo "Fixing ownership and permissions on remote (requires sudo on ${REMOTE_HOST})..."
  # When using SSH, the actual filesystem path is /volume1/docker/jeangodeyne/www
  REMOTE_SSH_PATH="/volume1${REMOTE_PATH}"
  if [[ $USE_SSHPASS -eq 1 ]]; then
    sshpass -p "$SSH_PASSWORD" ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
      "echo '$SSH_PASSWORD' | sudo -S chown -R ${CHOWN_ON_REMOTE} '${REMOTE_SSH_PATH}' && echo '$SSH_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type d -exec chmod 755 {} \; && echo '$SSH_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type f -exec chmod 644 {} \;"
  else
    # Prompt for the remote sudo password and pipe it to sudo via -S
    read -s -p "Enter sudo password for ${REMOTE_USER}@${REMOTE_HOST}: " SUDO_PASSWORD; echo
    ssh -p "${SSH_PORT}" "${REMOTE_USER}@${REMOTE_HOST}" \
      "echo '$SUDO_PASSWORD' | sudo -S chown -R ${CHOWN_ON_REMOTE} '${REMOTE_SSH_PATH}' && echo '$SUDO_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type d -exec chmod 755 {} \\; && echo '$SUDO_PASSWORD' | sudo -S find '${REMOTE_SSH_PATH}' -type f -exec chmod 644 {} \\;"
  fi
  echo "Permissions fixed."
fi

# Clean up password from memory
if [[ $USE_SSHPASS -eq 1 ]]; then
  unset SSH_PASSWORD
fi
if [[ -n "${SUDO_PASSWORD:-}" ]]; then
  unset SUDO_PASSWORD
fi

# Clean up password from memory
if [[ $USE_SSHPASS -eq 1 ]]; then
  unset SSH_PASSWORD
fi