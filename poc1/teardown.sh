#!/bin/bash
PROJECT_ID=$(gcloud config get-value project)
echo "Using project $PROJECT_ID"
echo "WARNING: This script will delete ALL resources created for the NCC PoC."
sleep 3

# Configuration mappings
declare -A REGIONS=(
  ["asia"]="asia-southeast1"
  ["us"]="us-west1"
  ["europe"]="europe-west4"
  ["sa"]="southamerica-east1"
)

declare -A ZONES=(
  ["asia"]="asia-southeast1-b"
  ["us"]="us-west1-b"
  ["europe"]="europe-west4-b"
  ["sa"]="southamerica-east1-b"
)

echo "====================================================="
echo "1. Deleting VMs"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  zone="${ZONES[$loc]}"
  gcloud compute instances delete vm-onprem-${loc} --zone=$zone --quiet || true
done

echo "====================================================="
echo "2. Deleting NCC Spokes and Hub"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gcloud network-connectivity spokes delete onprem-spoke-${loc} --region=$region --quiet || true
done

gcloud network-connectivity hubs delete ncc-routing-hub --quiet || true

echo "====================================================="
echo "3. Deleting Tunnels"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gcloud compute vpn-tunnels delete routing-to-onprem-${loc}-0 --region=$region --quiet || true
  gcloud compute vpn-tunnels delete onprem-to-routing-${loc}-0 --region=$region --quiet || true
  gcloud compute vpn-tunnels delete routing-to-onprem-${loc}-1 --region=$region --quiet || true
  gcloud compute vpn-tunnels delete onprem-to-routing-${loc}-1 --region=$region --quiet || true
done

echo "====================================================="
echo "4. Deleting Cloud Routers and HA VPN Gateways"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gcloud compute routers delete routing-cr-${loc} --region=$region --quiet || true
  gcloud compute routers delete onprem-cr-${loc} --region=$region --quiet || true
  gcloud compute vpn-gateways delete routing-vgw-${loc} --region=$region --quiet || true
  gcloud compute vpn-gateways delete onprem-vgw-${loc} --region=$region --quiet || true
done

echo "====================================================="
echo "5. Deleting Firewalls"
echo "====================================================="
gcloud compute firewall-rules delete routing-allow-ssh-icmp --quiet || true
for loc in "${!REGIONS[@]}"; do
  gcloud compute firewall-rules delete onprem-${loc}-allow-ssh-icmp --quiet || true
done

echo "====================================================="
echo "6. Deleting Subnets"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gcloud compute networks subnets delete routing-subnet-${loc} --region=$region --quiet || true
  gcloud compute networks subnets delete onprem-subnet-${loc} --region=$region --quiet || true
done

echo "====================================================="
echo "7. Deleting VPCs"
echo "====================================================="
gcloud compute networks delete routing-vpc --quiet || true
for loc in "${!REGIONS[@]}"; do
  gcloud compute networks delete onprem-${loc}-vpc --quiet || true
done

echo "Teardown Complete!"
