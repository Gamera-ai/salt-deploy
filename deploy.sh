#!/bin/bash
# This script can be used to deploy a new salt minio which operatse in headless mode
# Change the ROLE variable to the role you want to deploy.
# Author: Scaler LLC <support@scaler.io>

# Prompt for role and hostname
read -p "Enter role (e.g. nomad): " ROLE
read -p "Enter hostname (e.g. redis-ln-nj-001): " HOSTNAME

if [ -z "$ROLE" ] || [ -z "$HOSTNAME" ]; then
    echo "Error: Role and hostname cannot be empty"
    exit 1
fi

sudo hostnamectl set-hostname "$HOSTNAME"
rm -rf /srv/salt/ /root/salt/
cd /root
sudo apt-get update
sudo curl -L https://github.com/saltstack/salt-bootstrap/releases/latest/download/bootstrap-salt.sh -o bootstrap_salt.sh
sudo sh bootstrap_salt.sh -P stable 3006
sudo salt-call --local grains.set role "$ROLE"
sudo salt-call --local grains.set environment production
sudo salt-call --local grains.set GIT_BRANCH "main"
sudo apt-get install -y git openssl

# Prompt for decryption password
read -sp "Enter decryption password: " DECRYPT_PASSWORD
echo

# Encrypted and base64-encoded deployment key
ENCRYPTED_KEY="U2FsdGVkX1+grEN6i5DvfcH9s2sKtCv0AVC4DxefSJwoA5lp8a6YLFBWh+6wweFo
6mM3I0rDomkC+qWoeHU1rXlc3X/kqxsAp2lS0E0wZWsfmaZ9RgCwmvb/UNO69TJ/
6NUnGvdOFzZzqfriljaINcsHH4lm0ajF+0UL2ZIbGNf9CFypiGZn4T5H0jWAC+SA
m3B1rIDlUB0fZIdAvdI4BIUi0Di1tT2layL5gY6R76Kv9lDBURiIp1BmSiD497+m
RpTjaTyX7fUCdLz3p0cz9e4udd3JpGGko8F583iP/XTTg0wQQiy6+Qr6yMrBrzdr
xMiazQ1Q2KnDSj7Nnk76+tuX7CnxmXMV7Gs+e39CYEuo2wm5eGqet/ECeu0scYFy
J2I17QwAiOtu5jeyQ67iIBUc0syHuTxRRoQH6YAgrex+O+VV8+VK2w2mnTIUjSNv
bjlRkr6ckNPpLN9RMcIIcBuzYPKoSLRFIc/pPB12UY1wq9nxIdJI4z8zxyL9egpq
63Joz5zdmbBq/tR9z2TwhUssW0qGmnww8or1nrk09dYDSD1YwmCAJi++N11tJc92
"

# Decrypt and write the key to file
echo "$ENCRYPTED_KEY" | openssl enc -aes-256-cbc -d -pbkdf2 -base64 -pass pass:"$DECRYPT_PASSWORD" | sed '$a\' >/root/my-deployment.key 2>/dev/null

if [ $? -ne 0 ]; then
    echo "Error: Failed to decrypt the key. Please check your password."
    exit 1
fi

sudo chmod 600 /root/my-deployment.key
REPO_URL="git@github.com:Gamera-ai/salt.git"
DEPLOY_KEY_PATH="/root/my-deployment.key"

cd /root
# Add the deploy key to the ssh-agent
echo "Starting ssh-agent..."
eval $(ssh-agent -s)
ssh-add "$DEPLOY_KEY_PATH"

# Clone the repository
echo "Cloning repository..."
GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=no" git clone "$REPO_URL"

# Copy the salt minion config in place
cp salt/minion.config /etc/salt/minion

# Copy the salt deployment recipes in place
cp -R salt/salt /srv/

# Run the salt deployment
salt-call --local state.apply
