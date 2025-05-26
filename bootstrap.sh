#!/bin/bash

#####
# Variables
#####

# General variables
utility_node="192.168.56.151"
rhel_os_version="9.4"
ocp_version="4.16"
domain="imlab.priv"
tftp_server="$utility_node"
http_server="$utility_node"
dns_server="$utility_node"
dns_forwarders=("208.67.222.222" "208.67.220.220")
ntp_server="$utility_node"
ntp_sources=("0.rhel.pool.ntp.org" "1.rhel.pool.ntp.org" "2.rhel.pool.ntp.org" "3.rhel.pool.ntp.org")
dhcp_range=("192.168.56.15" "192.168.56.20")
network="192.168.56.0"
subnet="255.255.255.0"
subnet_cidr="24"
broadcast="192.168.56.255"
default_gateway="192.168.56.254"

# Required RHEL Repositories
# Required RHEL repositories
repos=(
  rhceph-8-tools-for-rhel-9-x86_64-rpms
  fast-datapath-for-rhel-9-x86_64-rpms
  rhoso-edpm-1.0-for-rhel-9-x86_64-rpms
  rhoso-18.0-for-rhel-9-x86_64-rpms
  rhoso-podified-1.0-for-rhel-9-x86_64-rpms
  rhoso-tools-18-for-rhel-9-x86_64-rpms
)

# Networks
storage_network="192.168.59.0"
storage_vlanid="60"
internalapi_network="192.168.57.0"
internalapi_vlanid="40"
storagemgmt_network="192.168.61.0"
storagemgmt_vlanid="70"
tenant_network="192.168.60.0"
tenant_vlanid="50"
ctrlplane_network="192.168.58.0"
ctrlplane_vlanid="30"
mirrored_disks=("disk1" "disk2")
osds=("sda" "sdb" "sdc" "sdd" "sde" "sdf" "sdg" "sdh" "sdi")
mon_ip="192.168.56.25"
storagemgmt_bootstrap_host="mbes005"
cluster_name="osp-control"
api_ip="192.168.56.35"
ingress_ip="192.168.56.36"
download_dir="/home/ansible/downloads"

# SSH variables
ANSIBLE_USER="ansible"
ANSIBLE_HOME="/home/$ANSIBLE_USER"
ANSIBLE_SSH_DIR="$ANSIBLE_HOME/.ssh"
ANSIBLE_KEY="$ANSIBLE_SSH_DIR/id_rsa"
ROOT_AUTH_KEYS="/root/.ssh/authorized_keys"

# Directory variables
BASE_DIR="/etc/ansible"
GROUP_VARS_DIR="$BASE_DIR/inventory/group_vars"

# Ansible roles
roles=("setup_dns" "setup_dhcp" "setup_httpd" "setup_tftp" "setup_pxeboot" "setup_http_repositories", "setup_pxe_boot")

# Hosts for hci_data_plane
declare -A utility_server_hosts=(
  ["utility-node01"]="ansible_host=$utility_node"
)

declare -A hci_data_plane_hosts=(
  ["mbes005"]="ansible_host=192.168.56.25 ilo_ip=192.168.55.25 storage_ip_address=192.168.59.25 storagemgmt_ip_address=192.168.61.25 tenant_ip_address=192.168.60.25 ctlplane_ip_address=192.168.58.25 mac_address=5c:ba:2c:8c:f3:00"
  ["mbes006"]="ansible_host=192.168.56.26 ilo_ip=192.168.55.26 storage_ip_address=192.168.59.26 storagemgmt_ip_address=192.168.61.26 tenant_ip_address=192.168.60.26 ctlplane_ip_address=192.168.58.26 mac_address=5c:ba:2c:8c:f7:00"
  ["mbes007"]="ansible_host=192.168.56.27 ilo_ip=192.168.55.27 storage_ip_address=192.168.59.27 storagemgmt_ip_address=192.168.61.27 tenant_ip_address=192.168.60.27 ctlplane_ip_address=192.168.58.27 mac_address=5c:ba:2c:8d:05:d0"
  ["mbes008"]="ansible_host=192.168.56.28 ilo_ip=192.168.55.28 storage_ip_address=192.168.59.28 storagemgmt_ip_address=192.168.61.28 tenant_ip_address=192.168.60.28 ctlplane_ip_address=192.168.58.28 mac_address=5c:ba:2c:8d:03:80"
  ["mbes009"]="ansible_host=192.168.56.29 ilo_ip=192.168.55.29 storage_ip_address=192.168.59.29 storagemgmt_ip_address=192.168.61.29 tenant_ip_address=192.168.60.29 ctlplane_ip_address=192.168.58.29 mac_address=5c:ba:2c:8d:92:f0"
  ["mbes010"]="ansible_host=192.168.56.30 ilo_ip=192.168.55.30 storage_ip_address=192.168.59.30 storagemgmt_ip_address=192.168.61.30 tenant_ip_address=192.168.60.30 ctlplane_ip_address=192.168.58.30 mac_address=5c:ba:2c:8d:00:90"
  ["mbes011"]="ansible_host=192.168.56.31 ilo_ip=192.168.55.31 storage_ip_address=192.168.59.31 storagemgmt_ip_address=192.168.61.31 tenant_ip_address=192.168.60.31 ctlplane_ip_address=192.168.58.31 mac_address=5c:ba:2c:8c:f1:a0"
  ["mbes012"]="ansible_host=192.168.56.32 ilo_ip=192.168.55.32 storage_ip_address=192.168.59.32 storagemgmt_ip_address=192.168.61.32 tenant_ip_address=192.168.60.32 ctlplane_ip_address=192.168.58.32 mac_address=5c:ba:2c:8d:05:80"
  ["mbes013"]="ansible_host=192.168.56.33 ilo_ip=192.168.55.33 storage_ip_address=192.168.59.33 storagemgmt_ip_address=192.168.61.33 tenant_ip_address=192.168.60.33 ctlplane_ip_address=192.168.58.33 mac_address=5c:ba:2c:8d:8e:c0"
)


# Hosts for ocp_control_plane
declare -A ocp_control_plane_hosts_mbes002=(
  [mac_address]="5c:ba:2c:8d:90:30"
  [ip_address]="192.168.56.22"
)

declare -A ocp_control_plane_hosts_mbes003=(
  [mac_address]="5c:ba:2c:8d:89:50"
  [ip_address]="192.168.56.23"
)

declare -A ocp_control_plane_hosts_mbes004=(
  [mac_address]="5c:ba:2c:8d:96:90"
  [ip_address]="192.168.56.24"
)

ocp_control_plane_hostnames=(
  mbes002
  mbes003
  mbes004
)


#####
# Script Execution
#####

# Create the ansible user
echo "Creating the 'ansible' user..."
sudo useradd -m -d "$ANSIBLE_HOME" -s /bin/bash "$ANSIBLE_USER"
echo "ansible:ansible123!" | sudo chpasswd
echo "The 'ansible' user has been created with the password."

# Add Ansible to sudoers with NOPASSWD
echo "Adding 'ansible' user to sudoers with NOPASSWD..."
echo "$ANSIBLE_USER ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/$ANSIBLE_USER

# Set release to RHEL 9.4
echo "Setting RHEL release to $rhel_os_version..."
sudo subscription-manager release --set "$rhel_os_version"

# Enable the required repository
echo "Enabling required RHEL repositories..."
for repo in "${repos[@]}"; do
  sudo subscription-manager repos --enable="$repo"
done

# Install Ansible Core and collections
echo "Installing Ansible Core and required collections..."
sudo yum install -y ansible-core
sudo yum install -y ansible-collection-redhat-rhel_mgmt

# Switch to the ansible user and install additional collections
sudo -u "$ANSIBLE_USER" ansible-galaxy collection install community.crypto
sudo -u "$ANSIBLE_USER" ansible-galaxy collection install community.general
sudo -u "$ANSIBLE_USER" ansible-galaxy collection install community.postgresql
sudo -u "$ANSIBLE_USER" ansible-galaxy collection install containers.podman

# Create Ansible directory structure
echo "Creating Ansible directory structure in $BASE_DIR..."
sudo mkdir -p "$BASE_DIR/roles" "$BASE_DIR/playbooks" "$BASE_DIR/inventory" "$GROUP_VARS_DIR"
sudo chown -R "$ANSIBLE_USER":"$ANSIBLE_USER" "$BASE_DIR"
sudo mkdir -p "$BASE_DIR/roles" "$BASE_DIR/playbooks" "$BASE_DIR/inventory" "$GROUP_VARS_DIR"
sudo chown -R "$ANSIBLE_USER":"$ANSIBLE_USER" "$BASE_DIR"
sudo chmod -R 755 "$BASE_DIR"

echo "Ansible directory structure created successfully!"

# Create ansible.cfg
sudo tee "$BASE_DIR/ansible.cfg" > /dev/null << EOF
[defaults]
inventory = $BASE_DIR/inventory/hosts
remote_user = root
host_key_checking = False
timeout = 60

[privilege_escalation]
become = True
become_method = sudo
become_user = root
become_ask_pass = False

[ssh_connection]
ssh_args = -o ControlMaster=auto -o ControlPersist=60s
pipelining = True
EOF

echo "Ansible configuration file created at $BASE_DIR/ansible.cfg"

#################################################################################
#################################################################################
# Optional Section if NOT using git to sync ansible content
# Create inventory and group_vars files
sudo tee "$BASE_DIR/inventory/hosts" > /dev/null << EOF
[utility_server]
$(for host in "${!utility_server_hosts[@]}"; do echo "$host ansible_connection=local ansible_become=true ansible_become_method=sudo ${utility_server_hosts[$host]}"; done)

[hci_data_plane]
$(for host in "${!hci_data_plane_hosts[@]}"; do echo "$host ansible_become=true ansible_become_method=sudo ${hci_data_plane_hosts[$host]}"; done)

[ocp_control_plane]
$(for host in "${ocp_control_plane_hostnames[@]}"; do
  declare -n hostvars="ocp_control_plane_hosts_$host"
  echo "$host ansible_become=true ansible_become_method=sudo ansible_host=${hostvars[ip_address]}"
done)
EOF
sudo chown "$ANSIBLE_USER":"$ANSIBLE_USER" "$BASE_DIR/inventory/hosts"


create_group_vars_file() {
  local group_name=$1
  local host_list_name=$2
  local host_prefix=$3

  declare -n host_list="$host_list_name"

  sudo tee "$GROUP_VARS_DIR/$group_name.yml" > /dev/null << EOF
hosts:
$(for hostname in "${host_list[@]}"; do
    declare -n host="${host_prefix}_${hostname}"  # dynamically point to the right per-host array
    echo "  - name: $hostname"
    echo "    mac_address: \"${host[mac_address]}\""
    echo "    ip_address: \"${host[ip_address]}\""
    echo "    mirrored_drives:"
    echo "      - sda"
    echo "      - sdb"
done)
EOF

  sudo chown "$ANSIBLE_USER":"$ANSIBLE_USER" "$GROUP_VARS_DIR/$group_name.yml"
  echo "Group vars for $group_name created successfully!"
}

create_group_vars_file "ocp_control_plane" ocp_control_plane_hostnames ocp_control_plane_hosts

# Populate group_vars/all.yml
echo "Adding variables to $GROUP_VARS_DIR/all.yml..."
sudo tee "$GROUP_VARS_DIR/all.yml" > /dev/null << EOF
# Global variables for all groups
rhel_os_version: "$rhel_os_version"
domain: "$domain"
dns_server: "$dns_server"
dns_forwarders:
$(for forwarder in "${dns_forwarders[@]}"; do echo "  - \"$forwarder\""; done)
ntp_server: "$ntp_server"
ntp_sources:
$(for ntp in "${ntp_sources[@]}"; do echo "  - \"$ntp\""; done)
network: "$network"
storage_network: "$storage_network"
storage_vlanid: "$storage_vlanid"
storagemgmt_network: "$storagemgmt_network"
storagemgmt_vlanid: "$storagemgmt_vlanid"
tenant_network: "$tenant_network"
tenant_vlanid: "$tenant_vlanid"
internalapi_network: "$internalapi_network"
internalapi_vlanid: "$internalapi_vlanid"
ctlplane_network: "$ctrlplane_network"
ctlplane_vlanid : "$ctrlplane_vlanid"
subnet: "$subnet"
subnet_cidr: "$subnet_cidr"
broadcast: "$broadcast"
default_gateway: "$default_gateway"
dhcp_range:
$(for ip in "${dhcp_range[@]}"; do echo "  - \"$ip\""; done)
tftp_server: "$tftp_server"
http_server: "$http_server"
repos:
  - rhel-9-for-x86_64-baseos-rpms
  - rhel-9-for-x86_64-appstream-rpms
  - rhceph-8-tools-for-rhel-9-x86_64-rpms
  - fast-datapath-for-rhel-9-x86_64-rpms
  - rhoso-edpm-1.0-for-rhel-9-x86_64-rpms
  - rhoso-18.0-for-rhel-9-x86_64-rpms
  - rhoso-podified-1.0-for-rhel-9-x86_64-rpms
  - rhoso-tools-18-for-rhel-9-x86_64-rpms
mirror_drives:
$(for disk in "${mirrored_disks[@]}"; do echo "  - \"$disk\""; done)
osds:
$(for osd in "${osds[@]}"; do echo "  - \"$osd\""; done)
vg_name: vg01
mon_ip: "$mon_ip"
bootstrap_host: "$storagemgmt_bootstrap_host" 
cluster_name: "$cluster_name"
api_ip: "$api_ip"
ingress_ip: "$ingress_ip"
ocp_version: "$ocp_version"
download_dir: "$download_dir"
EOF

sudo chown "$ANSIBLE_USER":"$ANSIBLE_USER" "$GROUP_VARS_DIR/all.yml"
echo "Variables added to $GROUP_VARS_DIR/all.yml successfully."

# Populate group_vars files
create_group_vars_file() {
  local group_name=$1
  local hosts_array_name=$2
  declare -n hosts="$hosts_array_name"  # create a nameref

  sudo tee "$GROUP_VARS_DIR/$group_name.yml" > /dev/null << EOF
hosts:
$(for host in "${!hosts[@]}"; do
  read -r mac ip <<< "${hosts[$host]}"
  echo "  - name: $host"
  echo "    mac_address: \"$mac\""
  echo "    ip_address: \"$ip\""
done)
EOF

  sudo chown "$ANSIBLE_USER":"$ANSIBLE_USER" "$GROUP_VARS_DIR/$group_name.yml"
}

#create_group_vars_file "hci_data_plane" hci_data_plane_hosts
#echo "Group variables files populated successfully!"

#################################################################################
#################################################################################
