#!/bin/bash

USER="admin"
PASS="admin"

# Define the nodes and their management IPs
NODES=("leaf11" "leaf12" "spine11" "spine12")
IPS=("172.40.40.2" "172.40.40.4" "172.40.40.3" "172.40.40.5")

GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RESET=$(printf '\033[0m')

# Force-clear the cached keys on the host machine before starting to prevent collisions
echo "🧹 Clearing old SSH host keys from your server memory..."
for IP in "${IPS[@]}"; do
    ssh-keygen -f "/root/.ssh/known_hosts" -R "$IP" &>/dev/null
done

# Check if sshpass is installed on your host server
if ! command -v sshpass &> /dev/null; then
    echo "❌ sshpass is missing. Installing it now..."
    sudo dnf install -y sshpass || sudo yum install -y sshpass
fi

# SSH Bypass Flags to force authentication through without confirmation prompts
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    IP="${IPS[$i]}"
    
    CFG_DIR="configs/fabric-config/${NODE}"
    DB_FILE="${CFG_DIR}/config_db.json"
    FRR_FILE="${CFG_DIR}/${NODE}.frr.conf"

    echo "--------------------------------------------------------"
    echo "${YELLOW}[$NODE] Processing Node...${RESET}"
    echo "--------------------------------------------------------"

    # ========================================================
    # STEP 1: PUSH & RELOAD CONFIG_DB.JSON
    # ========================================================
    if [ -f "$DB_FILE" ]; then
        echo "📤 Copying custom config_db.json to $NODE ($IP)..."
        sshpass -p "$PASS" scp $SSH_OPTS "$DB_FILE" "$USER@$IP:/tmp/config_db.json"
        
        echo "🔄 Applying config_db.json and saving changes..."
        sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$IP" "
            echo $PASS | sudo -S mv /tmp/config_db.json /etc/sonic/config_db.json &&
            sudo config reload -y &&
            sudo config save -y
        "
        echo "✅ Config DB Applied successfully."
    else
        echo "⚠️  Skipping DB copy: $DB_FILE not found."
    fi

    # ========================================================
    # STEP 2: PUSH & ACTIVATE FRR.CONF
    # ========================================================
    if [ -f "$FRR_FILE" ]; then
        echo "📤 Copying $NODE.frr.conf to $NODE ($IP)..."
        sshpass -p "$PASS" scp $SSH_OPTS "$FRR_FILE" "$USER@$IP:/tmp/frr.conf"
        
        echo "⚙️  Locking FRR into split-unified mode and restarting routing..."
        sshpass -p "$PASS" ssh $SSH_OPTS "$USER@$IP" "
            echo $PASS | sudo -S mkdir -p /etc/sonic/frr &&
            sudo mv /tmp/frr.conf /etc/sonic/frr/frr.conf &&
            sudo chown -R root:root /etc/sonic/frr/ &&
            sudo chmod 777 /etc/sonic/frr/frr.conf &&
            sudo sonic-cli -c 'configure terminal' -c 'router-configuration mode split-unified' &&
            sudo config save -y &&
            sudo docker restart bgp
        "
        echo "${GREEN}✅ FRR Configuration active and permanent for $NODE!${RESET}"
    else
        echo "⚠️  Skipping FRR copy: $FRR_FILE not found."
    fi
    echo ""
done

echo "${GREEN}🚀 All fabric configurations have been successfully pushed and loaded!${RESET}"

