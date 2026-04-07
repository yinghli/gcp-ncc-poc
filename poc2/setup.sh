#!/bin/bash
# Description: Automated setup script for NCC PoC 2 (Dual Gateway Asia)
# We omit 'set -e' to allow script to gracefully skip existing resources.

PROJECT_ID=$(gcloud config get-value project)
echo "Using project $PROJECT_ID"

# Enable required APIs
gcloud services enable compute.googleapis.com networkconnectivity.googleapis.com || true

# Configuration mappings
declare -A REGIONS=(
  ["us"]="us-west1"
  ["asia1"]="asia-southeast1"
  ["asia2"]="asia-southeast1"
)

declare -A ZONES=(
  ["us"]="us-west1-a"
  ["asia1"]="asia-southeast1-a"
  ["asia2"]="asia-southeast1-b"
)

# Using distinct subnets for simulated on-prem environments
declare -A SUBNETS_ONPREM=(
  ["us"]="10.1.1.0/24"
  ["asia1"]="10.1.2.0/24"
  ["asia2"]="10.1.3.0/24"
)

# Shared or distinct subnets in the routing VPC
declare -A SUBNETS_ROUTING=(
  ["us"]="10.0.1.0/24"
  ["asia1"]="10.0.2.0/24"
  ["asia2"]="10.0.3.0/24"
)

declare -A ASN_ONPREM=(
  ["us"]="65011"
  ["asia1"]="65012"
  ["asia2"]="65013"
)
ASN_ROUTING="65000"

# Distinct BGP prefixes to avoid overlap
declare -A VPN_BGP_OCTET=(
  ["us"]="1"
  ["asia1"]="2"
  ["asia2"]="3"
)

function gx() {
  "$@" || echo "--> Moving on (resource likely already exists)..."
}

echo "====================================================="
echo "1. Creating VPCs"
echo "====================================================="
gx gcloud compute networks create routing-vpc --subnet-mode=custom --bgp-routing-mode=global
for loc in "${!REGIONS[@]}"; do
  gx gcloud compute networks create onprem-${loc}-vpc --subnet-mode=custom --bgp-routing-mode=global
done

echo "====================================================="
echo "2. Creating Subnets"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  # Only create routing subnet once per key (or separated if distinct keys)
  # Here we use distinct keys to allow two subnets in same region or just one per location
  gx gcloud compute networks subnets create routing-subnet-${loc} --network=routing-vpc --region=$region --range=${SUBNETS_ROUTING[$loc]}
  gx gcloud compute networks subnets create onprem-subnet-${loc} --network=onprem-${loc}-vpc --region=$region --range=${SUBNETS_ONPREM[$loc]}
done

echo "====================================================="
echo "3. Creating Firewall Rules"
echo "====================================================="
gx gcloud compute firewall-rules create routing-allow-ssh-icmp --network=routing-vpc --allow tcp:22,icmp --source-ranges=35.235.240.0/20,10.0.0.0/8,192.168.0.0/16
for loc in "${!REGIONS[@]}"; do
  gx gcloud compute firewall-rules create onprem-${loc}-allow-ssh-icmp --network=onprem-${loc}-vpc --allow tcp:22,icmp --source-ranges=35.235.240.0/20,10.0.0.0/8,192.168.0.0/16
done

echo "====================================================="
echo "4. Creating HA VPN Gateways"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  # This automatically creates two routing gateways in Asia because we have asia1 and asia2 keys!
  gx gcloud compute vpn-gateways create routing-vgw-${loc} --network=routing-vpc --region=$region
  gx gcloud compute vpn-gateways create onprem-vgw-${loc} --network=onprem-${loc}-vpc --region=$region
done

echo "====================================================="
echo "5. Creating Cloud Routers"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gx gcloud compute routers create routing-cr-${loc} --network=routing-vpc --region=$region --asn=$ASN_ROUTING
  gx gcloud compute routers create onprem-cr-${loc} --network=onprem-${loc}-vpc --region=$region --asn=${ASN_ONPREM[$loc]}
done

echo "====================================================="
echo "6. Creating VPN Tunnels & Configuring BGP"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  
  # Tunnel 0
  gx gcloud compute vpn-tunnels create routing-to-onprem-${loc}-0 --peer-gcp-gateway=onprem-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=routing-cr-${loc} --vpn-gateway=routing-vgw-${loc} --interface=0
  gx gcloud compute vpn-tunnels create onprem-to-routing-${loc}-0 --peer-gcp-gateway=routing-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=onprem-cr-${loc} --vpn-gateway=onprem-vgw-${loc} --interface=0

  # Tunnel 1
  gx gcloud compute vpn-tunnels create routing-to-onprem-${loc}-1 --peer-gcp-gateway=onprem-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=routing-cr-${loc} --vpn-gateway=routing-vgw-${loc} --interface=1
  gx gcloud compute vpn-tunnels create onprem-to-routing-${loc}-1 --peer-gcp-gateway=routing-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=onprem-cr-${loc} --vpn-gateway=onprem-vgw-${loc} --interface=1
  
  sleep 3

  # BGP Configuration
  octet=${VPN_BGP_OCTET[$loc]}
  
  gx gcloud compute routers add-interface routing-cr-${loc} --interface-name=if-tunnel0-to-onprem --ip-address=169.254.${octet}.1 --mask-length=30 --vpn-tunnel=routing-to-onprem-${loc}-0 --region=$region
  gx gcloud compute routers add-bgp-peer routing-cr-${loc} --peer-name=bgp-to-onprem-0 --interface=if-tunnel0-to-onprem --peer-ip-address=169.254.${octet}.2 --peer-asn=${ASN_ONPREM[$loc]} --region=$region

  gx gcloud compute routers add-interface onprem-cr-${loc} --interface-name=if-tunnel0-to-routing --ip-address=169.254.${octet}.2 --mask-length=30 --vpn-tunnel=onprem-to-routing-${loc}-0 --region=$region
  gx gcloud compute routers add-bgp-peer onprem-cr-${loc} --peer-name=bgp-to-routing-0 --interface=if-tunnel0-to-routing --peer-ip-address=169.254.${octet}.1 --peer-asn=$ASN_ROUTING --region=$region

  gx gcloud compute routers add-interface routing-cr-${loc} --interface-name=if-tunnel1-to-onprem --ip-address=169.254.${octet}.5 --mask-length=30 --vpn-tunnel=routing-to-onprem-${loc}-1 --region=$region
  gx gcloud compute routers add-bgp-peer routing-cr-${loc} --peer-name=bgp-to-onprem-1 --interface=if-tunnel1-to-onprem --peer-ip-address=169.254.${octet}.6 --peer-asn=${ASN_ONPREM[$loc]} --region=$region

  gx gcloud compute routers add-interface onprem-cr-${loc} --interface-name=if-tunnel1-to-routing --ip-address=169.254.${octet}.6 --mask-length=30 --vpn-tunnel=onprem-to-routing-${loc}-1 --region=$region
  gx gcloud compute routers add-bgp-peer onprem-cr-${loc} --peer-name=bgp-to-routing-1 --interface=if-tunnel1-to-routing --peer-ip-address=169.254.${octet}.5 --peer-asn=$ASN_ROUTING --region=$region
done

echo "====================================================="
echo "7. Creating NCC Hub and Spokes"
echo "====================================================="
if ! gcloud network-connectivity hubs describe ncc-routing-hub-poc2 >/dev/null 2>&1; then
  gx gcloud network-connectivity hubs create ncc-routing-hub-poc2 --description="NCC Hub for site-to-site transfer (PoC 2)"
fi

for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  tunnel0="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${region}/vpnTunnels/routing-to-onprem-${loc}-0"
  tunnel1="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${region}/vpnTunnels/routing-to-onprem-${loc}-1"
  gx gcloud network-connectivity spokes linked-vpn-tunnels create onprem-spoke-${loc}-poc2 \
    --hub=ncc-routing-hub-poc2 \
    --region=$region \
    --vpn-tunnels="${tunnel0},${tunnel1}" \
    --site-to-site-data-transfer \
    --description="Spoke for simulated $loc on-prem region (PoC 2)"
done

echo "====================================================="
echo "8. Creating Test VMs"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  zone="${ZONES[$loc]}"
  gx gcloud compute instances create vm-onprem-${loc} \
    --zone=$zone \
    --machine-type=e2-micro \
    --network=onprem-${loc}-vpc \
    --subnet=onprem-subnet-${loc} \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=allow-ssh
done

echo "====================================================="
echo "PoC 2 Setup Complete!"
echo "====================================================="
