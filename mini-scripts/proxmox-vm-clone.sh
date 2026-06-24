#!/bin/bash

#===============================================================================
# Proxmox VM Cloning Script
# Description: Clone a template VM with automatic configuration
# - Auto-detect available templates
# - Generate random secure password for root
# - Configure static IP address
# - Enable SSH root login
#===============================================================================

set -e  # Exit on any error

#===============================================================================
# Function: Display templates and let user select one
#===============================================================================
select_template() {
    echo "=== Scanning for available templates ==="
    
    # Store template information in arrays
    local template_ids=()
    local template_names=()
    local template_info=()
    
    # Find all templates
    for vmid in $(qm list | awk 'NR>1{print $1}'); do
        if qm config $vmid 2>/dev/null | grep -q '^template: 1$'; then
            template_ids+=("$vmid")
            
            # Get template name and other info
            local vm_info=$(qm list | awk -v id=$vmid '$1==id{print}')
            template_info+=("$vm_info")
            
            # Extract name from vm_info
            local vm_name=$(echo "$vm_info" | awk '{print $2}')
            template_names+=("$vm_name")
        fi
    done
    
    # Check if any templates found
    if [ ${#template_ids[@]} -eq 0 ]; then
        echo "Error: No templates found!"
        exit 1
    fi
    
    # Display templates with numbering
    echo ""
    echo "Available templates:"
    echo "-----------------------------------------------------------"
    for i in "${!template_ids[@]}"; do
        echo "$((i+1)). ${template_info[$i]}"
    done
    echo "-----------------------------------------------------------"
    echo ""
    
    # Prompt user to select
    read -p "Select template (1-${#template_ids[@]}) [default: 1]: " selection
    
    # Use default if empty
    if [ -z "$selection" ]; then
        selection=1
    fi
    
    # Validate selection
    if ! [[ "$selection" =~ ^[0-9]+$ ]] || [ "$selection" -lt 1 ] || [ "$selection" -gt ${#template_ids[@]} ]; then
        echo "Error: Invalid selection!"
        exit 1
    fi
    
    # Return selected template ID (adjust index since array is 0-based)
    TEMPLATE_ID=${template_ids[$((selection-1))]}
    TEMPLATE_NAME=${template_names[$((selection-1))]}
    
    echo "Selected template: ID=$TEMPLATE_ID, Name=$TEMPLATE_NAME"
    echo ""
}

#===============================================================================
# Function: Find an available VM ID in range 200-999
#===============================================================================
find_available_vmid() {
    echo "=== Finding available VM ID ==="
    NEW_VM_ID=200
    while qm status $NEW_VM_ID &>/dev/null; do
        NEW_VM_ID=$((NEW_VM_ID + 1))
        if [ $NEW_VM_ID -gt 999 ]; then
            echo "Error: No available VM ID found in range 200-999!"
            exit 1
        fi
    done
    echo "Found available VM ID: $NEW_VM_ID"
    echo ""
}

#===============================================================================
# Function: Prompt for VM name with default value
#===============================================================================
prompt_vm_name() {
    local default_name="clone-$TEMPLATE_NAME-$NEW_VM_ID"
    read -p "Enter VM name [default: $default_name]: " VM_NAME
    
    # Use default if empty
    if [ -z "$VM_NAME" ]; then
        VM_NAME="$default_name"
    fi
    
    echo "VM name set to: $VM_NAME"
    echo ""
}

#===============================================================================
# Function: Generate random IP in range 192.168.2.160-250
#===============================================================================
generate_random_ip() {
    RANDOM_IP="192.168.2.$((160 + RANDOM % 91))"
    echo "Generated IP: $RANDOM_IP"
}

#===============================================================================
# Function: Wait for guest agent to be ready
#===============================================================================
wait_for_guest_agent() {
    local vmid=$1
    local max_attempts=60
    local attempt=0
    
    echo "=== Waiting for guest agent to be ready ==="
    
    while [ $attempt -lt $max_attempts ]; do
        if qm guest exec $vmid -- echo "ready" &>/dev/null; then
            echo "Guest agent is ready!"
            return 0
        fi
        
        echo -n "."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo ""
    echo "Warning: Guest agent not responding after $((max_attempts * 2)) seconds"
    echo "Proceeding anyway, but configuration may fail..."
    return 1
}

#===============================================================================
# Main Script Execution
#===============================================================================

echo "========================================"
echo "  Proxmox VM Cloning Script"
echo "========================================"
echo ""

# Step 1: Select template
select_template

# Step 2: Find available VM ID
find_available_vmid

# Step 3: Prompt for VM name
prompt_vm_name

# Step 4: Generate credentials and network config
NEW_PASSWORD=$(openssl rand -base64 16)
generate_random_ip
NEW_HOSTNAME="vm-$NEW_VM_ID"

echo "=== Configuration Summary ==="
echo "Template ID: $TEMPLATE_ID"
echo "New VM ID: $NEW_VM_ID"
echo "VM Name: $VM_NAME"
echo "Hostname: $NEW_HOSTNAME"
echo "IP Address: $RANDOM_IP"
echo "Root Password: $NEW_PASSWORD"
echo ""

read -p "Proceed with cloning? (y/n) [default: y]: " confirm
if [ ! -z "$confirm" ] && [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted by user."
    exit 0
fi

#===============================================================================
# Clone and configure VM
#===============================================================================

echo ""
echo "=== Cloning VM ==="
if ! qm clone $TEMPLATE_ID $NEW_VM_ID --name "$VM_NAME" --full; then
    echo "Error: Failed to clone VM!"
    exit 1
fi
sleep 3

echo "=== Starting VM ==="
if ! qm start $NEW_VM_ID; then
    echo "Error: Failed to start VM!"
    exit 1
fi

# Wait for VM to boot and guest agent to start
wait_for_guest_agent $NEW_VM_ID

echo ""
echo "=== Configuring root password ==="
if ! qm guest exec $NEW_VM_ID -- bash -c "echo 'root:$NEW_PASSWORD' | chpasswd"; then
    echo "Warning: Failed to set root password"
fi

echo "=== Enabling SSH root login ==="
# Enable root login via SSH by modifying sshd_config
if ! qm guest exec $NEW_VM_ID -- bash -c "sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config && sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && systemctl restart sshd"; then
    echo "Warning: Failed to enable SSH root login"
fi

echo "=== Setting hostname ==="
if ! qm guest exec $NEW_VM_ID -- bash -c "hostnamectl set-hostname $NEW_HOSTNAME"; then
    echo "Warning: Failed to set hostname"
fi

echo "=== Configuring static IP ==="
if ! qm guest exec $NEW_VM_ID -- bash -c "echo 'network:
  version: 2
  renderer: networkd
  ethernets:
    ens18:
      dhcp4: no
      addresses:
        - $RANDOM_IP/20
      gateway4: 192.168.1.1
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]' > /etc/netplan/01-static.yaml"; then
    echo "Warning: Failed to configure network"
fi

echo "=== Applying network configuration ==="
if ! qm guest exec $NEW_VM_ID -- bash -c "netplan apply"; then
    echo "Warning: Failed to apply network configuration"
fi

#===============================================================================
# Display final information
#===============================================================================

echo ""
echo "========================================"
echo "  VM Cloning Completed Successfully!"
echo "========================================"
echo ""
echo "VM Details:"
echo "  VM ID:       $NEW_VM_ID"
echo "  VM Name:     $VM_NAME"
echo "  Hostname:    $NEW_HOSTNAME"
echo "  IP Address:  $RANDOM_IP"
echo "  Username:    root"
echo "  Password:    $NEW_PASSWORD"
echo ""
echo "SSH Command:"
echo "  ssh root@$RANDOM_IP"
echo ""
echo "========================================"

# Optional: Save credentials to log file
LOG_FILE="/var/log/vm-clones.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') | VM_ID: $NEW_VM_ID | Name: $VM_NAME | IP: $RANDOM_IP | Password: $NEW_PASSWORD" >> "$LOG_FILE"
echo "Credentials saved to: $LOG_FILE"