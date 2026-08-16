# salt-deploy

Deploy a Salt minion in headless mode.

## Interactive deployment

Run `deploy.sh` as root. Enter the Salt role, hostname, and deployment-key password when the script prompts for them.

## Unattended deployment

`deploy-unattended.sh` accepts the role and hostname as arguments. It reads the deployment-key password from a protected environment file or standard input. It updates and upgrades installed packages before it changes the host configuration.

Create the local environment file:

```bash
cp .env.example .env
chmod 600 .env
$EDITOR .env
```

Run the deployment:

```bash
sudo ./deploy-unattended.sh \
  --role swarm \
  --hostname gamera-scrp-va-065 \
  --env-file .env
```

For remote automation, keep `.env` on the operator host. Send only the password through SSH standard input.

```bash
TARGET=gamera-scrp-va-065
REMOTE_DIR=/tmp/salt-deploy

ssh "$TARGET" "rm -rf '$REMOTE_DIR' && mkdir -m 700 '$REMOTE_DIR'"
scp deploy.sh deploy-unattended.sh "$TARGET:$REMOTE_DIR/"

. ./.env
printf '%s\n' "$SALT_DEPLOY_PASSWORD" | \
  ssh "$TARGET" \
    "sudo -n bash '$REMOTE_DIR/deploy-unattended.sh' \
      --role swarm \
      --hostname gamera-scrp-va-065 \
      --password-stdin"
unset SALT_DEPLOY_PASSWORD

ssh "$TARGET" "rm -rf '$REMOTE_DIR'"
```

Do not commit `.env`. Do not copy it to managed nodes.
