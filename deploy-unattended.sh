#!/bin/bash

set -Eeuo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROLE=""
TARGET_HOSTNAME=""
ENV_FILE="$SCRIPT_DIR/.env"
PASSWORD_STDIN=false
WORK_DIR=""

usage() {
    cat <<'EOF'
Usage:
  deploy-unattended.sh --role ROLE --hostname HOSTNAME [--env-file PATH]
  deploy-unattended.sh --role ROLE --hostname HOSTNAME --password-stdin

Options:
  --role ROLE          Set the Salt role grain.
  --hostname HOSTNAME  Set the system hostname.
  --env-file PATH      Read SALT_DEPLOY_PASSWORD from PATH. Default: .env beside this script.
  --password-stdin     Read SALT_DEPLOY_PASSWORD from standard input.
  -h, --help           Show this help text.
EOF
}

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    unset SALT_DEPLOY_PASSWORD || true
    if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}

load_password_from_env_file() {
    local file=$1
    local mode
    local owner
    local permitted_owner=${SUDO_UID:-$EUID}

    [[ -f "$file" && ! -L "$file" ]] || fail "The environment file is not a regular file: $file"

    mode=$(stat -c '%a' "$file")
    if (( (8#$mode & 8#077) != 0 )); then
        fail "The environment file must not be accessible by group or other users: $file"
    fi

    owner=$(stat -c '%u' "$file")
    if [[ "$owner" != "$EUID" && "$owner" != "$permitted_owner" ]]; then
        fail "The environment file has an unexpected owner: $file"
    fi

    unset SALT_DEPLOY_PASSWORD || true
    # The environment file is trusted operator input and must contain shell-compatible assignments.
    # shellcheck disable=SC1090
    source "$file"
    export -n SALT_DEPLOY_PASSWORD 2>/dev/null || true
}

extract_encrypted_key() {
    local interactive_script="$SCRIPT_DIR/deploy.sh"

    [[ -f "$interactive_script" ]] || fail "The interactive deploy script is missing: $interactive_script"

    awk '
        /^ENCRYPTED_KEY="/ {
            collecting = 1
            sub(/^ENCRYPTED_KEY="/, "")
        }
        collecting {
            if ($0 == "\"") {
                exit
            }
            print
        }
    ' "$interactive_script"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)
            [[ $# -ge 2 ]] || fail "--role requires a value."
            ROLE=$2
            shift 2
            ;;
        --hostname)
            [[ $# -ge 2 ]] || fail "--hostname requires a value."
            TARGET_HOSTNAME=$2
            shift 2
            ;;
        --env-file)
            [[ $# -ge 2 ]] || fail "--env-file requires a value."
            ENV_FILE=$2
            shift 2
            ;;
        --password-stdin)
            PASSWORD_STDIN=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ $EUID -eq 0 ]] || fail "Run this script as root."
[[ -n "$ROLE" ]] || fail "--role is required."
[[ -n "$TARGET_HOSTNAME" ]] || fail "--hostname is required."
[[ "$ROLE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || fail "The role contains invalid characters."
[[ ${#TARGET_HOSTNAME} -le 253 ]] || fail "The hostname is too long."
[[ "$TARGET_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || fail "The hostname is invalid."
[[ "$TARGET_HOSTNAME" != *..* ]] || fail "The hostname is invalid."

if [[ "$PASSWORD_STDIN" == true ]]; then
    IFS= read -r SALT_DEPLOY_PASSWORD || fail "Cannot read SALT_DEPLOY_PASSWORD from standard input."
else
    load_password_from_env_file "$ENV_FILE"
fi

[[ -n "${SALT_DEPLOY_PASSWORD:-}" ]] || fail "SALT_DEPLOY_PASSWORD is empty."

trap cleanup EXIT
WORK_DIR=$(mktemp -d /root/salt-deploy.XXXXXX)

export DEBIAN_FRONTEND=noninteractive
printf 'Updating installed packages.\n'
apt-get update
apt-get upgrade -y
apt-get install -y ca-certificates curl git openssl openssh-client

printf 'Configuring host %s with Salt role %s.\n' "$TARGET_HOSTNAME" "$ROLE"
hostnamectl set-hostname "$TARGET_HOSTNAME"

curl --fail --location --silent --show-error \
    https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh \
    --output "$WORK_DIR/bootstrap-salt.sh"
sh "$WORK_DIR/bootstrap-salt.sh" -P stable 3006

ENCRYPTED_KEY=$(extract_encrypted_key)
[[ "$ENCRYPTED_KEY" == U2FsdGVkX1* ]] || fail "Cannot read the encrypted deployment key from deploy.sh."

DECRYPTED_KEY="$WORK_DIR/my-deployment.key"
if ! openssl enc -aes-256-cbc -d -pbkdf2 -base64 \
    -pass fd:3 \
    3<<<"$SALT_DEPLOY_PASSWORD" \
    <<<"$ENCRYPTED_KEY" \
    >"$DECRYPTED_KEY" 2>/dev/null; then
    fail "Cannot decrypt the deployment key."
fi
printf '\n' >>"$DECRYPTED_KEY"
chmod 600 "$DECRYPTED_KEY"

if ! ssh-keygen -y -P '' -f "$DECRYPTED_KEY" >/dev/null 2>&1; then
    fail "The decrypted deployment key is invalid."
fi

install -m 600 "$DECRYPTED_KEY" /root/my-deployment.key
unset SALT_DEPLOY_PASSWORD

REPOSITORY_DIR="$WORK_DIR/salt"
printf 'Cloning the Salt repository.\n'
GIT_SSH_COMMAND='ssh -i /root/my-deployment.key -o IdentitiesOnly=yes -o StrictHostKeyChecking=no' \
    git clone git@github.com:Gamera-ai/salt.git "$REPOSITORY_DIR"

[[ -f "$REPOSITORY_DIR/minion.config" ]] || fail "The Salt repository does not contain minion.config."
[[ -f "$REPOSITORY_DIR/top.sls" ]] || fail "The Salt repository does not contain top.sls."

rm -rf /root/salt.next /srv/salt.next
cp -a "$REPOSITORY_DIR" /root/salt.next
cp -a "$REPOSITORY_DIR" /srv/salt.next
rm -rf /root/salt /srv/salt
mv /root/salt.next /root/salt
mv /srv/salt.next /srv/salt
install -m 644 /root/salt/minion.config /etc/salt/minion

salt-call --local --retcode-passthrough grains.set role "$ROLE"
salt-call --local --retcode-passthrough grains.set environment production
salt-call --local --retcode-passthrough grains.set GIT_BRANCH main
salt-call --local --retcode-passthrough saltutil.clear_cache
salt-call --local --retcode-passthrough saltutil.sync_all
salt-call --local --retcode-passthrough state.apply

printf 'Salt deployment completed for %s.\n' "$TARGET_HOSTNAME"
