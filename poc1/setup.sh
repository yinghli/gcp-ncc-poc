#!/bin/bash
# We are omitting 'set -e' specifically to allow the script 
# to gracefully skip over resources that already exist.

PROJECT_ID=$(gcloud config get-value project)
echo "Using project $PROJECT_ID"

# Enable required APIs
gcloud services enable compute.googleapis.com networkconnectivity.googleapis.com || true

# Configuration mappings
declare -A REGIONS=(
  ["asia"]="asia-southeast1"
  ["us"]="us-west1"
  ["europe"]="europe-west4"
  ["sa"]="southamerica-east1"
)

# Using specific zones suitable for VM deployment
declare -A ZONES=(
  ["asia"]="asia-southeast1-b"
  ["us"]="us-west1-b"
  ["europe"]="europe-west4-b"
  ["sa"]="southamerica-east1-b"
)

declare -A SUBNETS_ROUTING=(
  ["asia"]="10.0.1.0/24"
  ["us"]="10.0.2.0/24"
  ["europe"]="10.0.3.0/24"
  ["sa"]="10.0.4.0/24"
)

declare -A SUBNETS_ONPREM=(
  ["asia"]="10.1.1.0/24"
  ["us"]="10.1.2.0/24"
  ["europe"]="10.1.3.0/24"
  ["sa"]="10.1.4.0/24"
)

declare -A ASN_ONPREM=(
  ["asia"]="65011"
  ["us"]="65012"
  ["europe"]="65013"
  ["sa"]="65014"
)
ASN_ROUTING="65000"

declare -A VPN_BGP_OCTET=(
  ["asia"]="1"
  ["us"]="2"
  ["europe"]="3"
  ["sa"]="4"
)

# Helper function to ignore "already exists" errors but fail on real ones optionally
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
  
  # create tunnel 0
  gx gcloud compute vpn-tunnels create routing-to-onprem-${loc}-0 --peer-gcp-gateway=onprem-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=routing-cr-${loc} --vpn-gateway=routing-vgw-${loc} --interface=0
  gx gcloud compute vpn-tunnels create onprem-to-routing-${loc}-0 --peer-gcp-gateway=routing-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=onprem-cr-${loc} --vpn-gateway=onprem-vgw-${loc} --interface=0

  # create tunnel 1
  gx gcloud compute vpn-tunnels create routing-to-onprem-${loc}-1 --peer-gcp-gateway=onprem-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=routing-cr-${loc} --vpn-gateway=routing-vgw-${loc} --interface=1
  gx gcloud compute vpn-tunnels create onprem-to-routing-${loc}-1 --peer-gcp-gateway=routing-vgw-${loc} --region=$region --ike-version=2 --shared-secret=secret123 --router=onprem-cr-${loc} --vpn-gateway=onprem-vgw-${loc} --interface=1
  
  # Wait briefly for tunnels to be recognized by routers
  sleep 3

  # BGP configuration
  # routing router interface 0 and peer
  gx gcloud compute routers add-interface routing-cr-${loc} --interface-name=if-tunnel0-to-onprem --ip-address=169.254.${VPN_BGP_OCTET[$loc]}.1 --mask-length=30 --vpn-tunnel=routing-to-onprem-${loc}-0 --region=$region
  gx gcloud compute routers add-bgp-peer routing-cr-${loc} --peer-name=bgp-to-onprem-0 --interface=if-tunnel0-to-onprem --peer-ip-address=169.254.${VPN_BGP_OCTET[$loc]}.2 --peer-asn=${ASN_ONPREM[$loc]} --region=$region

  # onprem router interface 0 and peer
  gx gcloud compute routers add-interface onprem-cr-${loc} --interface-name=if-tunnel0-to-routing --ip-address=169.254.${VPN_BGP_OCTET[$loc]}.2 --mask-length=30 --vpn-tunnel=onprem-to-routing-${loc}-0 --region=$region
  gx gcloud compute routers add-bgp-peer onprem-cr-${loc} --peer-name=bgp-to-routing-0 --interface=if-tunnel0-to-routing --peer-ip-address=169.254.${VPN_BGP_OCTET[$loc]}.1 --peer-asn=$ASN_ROUTING --region=$region

  # routing router interface 1 and peer
  gx gcloud compute routers add-interface routing-cr-${loc} --interface-name=if-tunnel1-to-onprem --ip-address=169.254.${VPN_BGP_OCTET[$loc]}.5 --mask-length=30 --vpn-tunnel=routing-to-onprem-${loc}-1 --region=$region
  gx gcloud compute routers add-bgp-peer routing-cr-${loc} --peer-name=bgp-to-onprem-1 --interface=if-tunnel1-to-onprem --peer-ip-address=169.254.${VPN_BGP_OCTET[$loc]}.6 --peer-asn=${ASN_ONPREM[$loc]} --region=$region
  
  # onprem router interface 1 and peer
  gx gcloud compute routers add-interface onprem-cr-${loc} --interface-name=if-tunnel1-to-routing --ip-address=169.254.${VPN_BGP_OCTET[$loc]}.6 --mask-length=30 --vpn-tunnel=onprem-to-routing-${loc}-1 --region=$region
  gx gcloud compute routers add-bgp-peer onprem-cr-${loc} --peer-name=bgp-to-routing-1 --interface=if-tunnel1-to-routing --peer-ip-address=169.254.${VPN_BGP_OCTET[$loc]}.5 --peer-asn=$ASN_ROUTING --region=$region
done

echo "====================================================="
echo "7. Creating NCC Hub and Spokes"
echo "====================================================="
# Check if Hub exists, if not create
if ! gcloud network-connectivity hubs describe ncc-routing-hub >/dev/null 2>&1; then
  gx gcloud network-connectivity hubs create ncc-routing-hub --description="NCC Hub for site-to-site transfer"
fi

for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  tunnel0="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${region}/vpnTunnels/routing-to-onprem-${loc}-0"
  tunnel1="https://www.googleapis.com/compute/v1/projects/${PROJECT_ID}/regions/${region}/vpnTunnels/routing-to-onprem-${loc}-1"
  gx gcloud network-connectivity spokes linked-vpn-tunnels create onprem-spoke-${loc} \
    --hub=ncc-routing-hub \
    --region=$region \
    --vpn-tunnels="${tunnel0},${tunnel1}" \
    --site-to-site-data-transfer \
    --description="Spoke for simulated $loc on-prem region"
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
echo "Setup Complete!"
echo "Use 'gcloud compute routers get-status' to check BGP sessions."
echo "Use 'gcloud network-connectivity hubs describe ncc-routing-hub' to check NCC."
echo "====================================================="
