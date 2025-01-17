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
sudo apt-get update
sudo curl -L https://bootstrap.saltstack.com -o bootstrap_salt.sh
sudo sh bootstrap_salt.sh -P stable 3006
sudo salt-call --local grains.set role "$ROLE"
sudo salt-call --local grains.set environment production
sudo salt-call --local grains.set GIT_BRANCH "main"
sudo apt-get install -y git openssl

# Prompt for decryption password
read -sp "Enter decryption password: " DECRYPT_PASSWORD
echo

# Encrypted and base64-encoded deployment key
ENCRYPTED_KEY="U2FsdGVkX1+ghwbCo/riqZDqIpquwsw/EzdO7J4VNrZLHBadVR596m2tWrXJt4Gl
GH4eBG/KoQC3mhg4jA/xioAfnrlvJ+PEXhQnCxgL5Mlb5t43Kg63SxDcR4BHBa5o
G/vFC0JwSW0Y4O1VYLxnemaNgnAkMTfgclaRHGDx8g1Hn0NP0fF1ECwaUXxRUu92
CbuYOw9/1N48tOkhgE2/B4dj3G5tYLdEfAmhIlcdYGE8Onn/6WkqSg/JZkBHrkl8
ndXzaOpihJbfoahXfAUY01OPpkPlFlkMCRPhvBfSQsIVdXpqzT/vZLmFHhf2oMLQ
PionOP8KgvergcB7GtKb/+6OVxKIPGMpHuwjIbR+BKTpJNGyFQU6UItT4Ca69icD
fTb7cV/vg5KDW22N18RQ6TMcxyLfZQL/tIVwxjaczly5NaZaOZe05QznSPGh4cJH
7tHk0TM1POFixDcIjCHM4JlmgRmHAqJGWHArs8mLPQdy9TeE70A9/rFl8uMNgZw4
NpGU41OAchaMu2vOlLR5i3Drom5gQbp8Ugml7ALjSGHYdP0GJ9qvDsD1TB+hRk1S"

# Decrypt and write the key to file
echo "$ENCRYPTED_KEY" | openssl enc -aes-256-cbc -d -pbkdf2 -base64 -pass pass:"$DECRYPT_PASSWORD" >/root/my-deployment.key 2>/dev/null

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
