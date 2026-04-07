#!/bin/bash
# Description: Automated teardown script for NCC PoC 2
# We use '|| true' to allow the script to proceed even if resources were already deleted.

PROJECT_ID=$(gcloud config get-value project)
echo "Using project $PROJECT_ID"

declare -A REGIONS=(
  ["us"]="us-west1"
  ["asia1"]="asia-southeast1"
  ["asia2"]="asia-southeast1"
)

function gx_del() {
  "$@" || echo "--> Moving on (resource likely already deleted)..."
}

echo "====================================================="
echo "1. Deleting Test VMs"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  zone=$(gcloud compute instances list --filter="name:vm-onprem-${loc}" --format="value(zone)" 2>/dev/null)
  if [ -n "$zone" ]; then
    gx_del gcloud compute instances delete vm-onprem-${loc} --zone=$zone --quiet
  fi
done

echo "====================================================="
echo "2. Deleting NCC Spokes"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gx_del gcloud network-connectivity spokes delete onprem-spoke-${loc}-poc2 --region=$region --quiet
done

echo "====================================================="
echo "3. Deleting NCC Hub"
echo "====================================================="
gx_del gcloud network-connectivity hubs delete ncc-routing-hub-poc2 --quiet

echo "====================================================="
echo "4. Deleting VPN Tunnels and BGP sessions (via Routers)"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  
  # Routers delete their interfaces/peers when deleted, but we can delete tunnels first
  gx_del gcloud compute vpn-tunnels delete routing-to-onprem-${loc}-0 --region=$region --quiet
  gx_del gcloud compute vpn-tunnels delete onprem-to-routing-${loc}-0 --region=$region --quiet
  gx_del gcloud compute vpn-tunnels delete routing-to-onprem-${loc}-1 --region=$region --quiet
  gx_del gcloud compute vpn-tunnels delete onprem-to-routing-${loc}-1 --region=$region --quiet
done

echo "====================================================="
echo "5. Deleting Cloud Routers"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gx_del gcloud compute routers delete routing-cr-${loc} --region=$region --quiet
  gx_del gcloud compute routers delete onprem-cr-${loc} --region=$region --quiet
done

echo "====================================================="
echo "6. Deleting HA VPN Gateways"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gx_del gcloud compute vpn-gateways delete routing-vgw-${loc} --region=$region --quiet
  gx_del gcloud compute vpn-gateways delete onprem-vgw-${loc} --region=$region --quiet
done

echo "====================================================="
echo "7. Deleting Firewalls"
echo "====================================================="
gx_del gcloud compute firewall-rules delete routing-allow-ssh-icmp --quiet
for loc in "${!REGIONS[@]}"; do
  gx_del gcloud compute firewall-rules delete onprem-${loc}-allow-ssh-icmp --quiet
done

echo "====================================================="
echo "8. Deleting Subnets"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  region="${REGIONS[$loc]}"
  gx_del gcloud compute networks subnets delete routing-subnet-${loc} --region=$region --quiet
  gx_del gcloud compute networks subnets delete onprem-subnet-${loc} --region=$region --quiet
done

echo "====================================================="
echo "9. Deleting VPCs"
echo "====================================================="
for loc in "${!REGIONS[@]}"; do
  gx_del gcloud compute networks delete onprem-${loc}-vpc --quiet
done
# Delete routing-vpc last if it's empty
gx_del gcloud compute networks delete routing-vpc --quiet

echo "====================================================="
echo "PoC 2 Teardown Complete!"
echo "====================================================="
