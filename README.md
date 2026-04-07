# Google Cloud Network Connectivity Center (NCC) PoC

This repository contains scripts to simulate multi-site connectivity using Google Cloud Network Connectivity Center (NCC). It includes two different Proof of Concept (PoC) scenarios.

## Prerequisites
- Google Cloud Project with billing enabled.
- `gcloud` CLI installed and configured.
- Sufficient quota for VPCs, VPN Gateways, and Compute Instances.
- APIs enabled: `compute.googleapis.com`, `networkconnectivity.googleapis.com`.

## PoC 1: 4-Site Global Interconnect Simulation
This PoC simulates connecting 4 distinct on-premises environments across global regions using a central routing VPC and NCC site-to-site data transfer.

### Topology
- **Regions**: `asia-southeast1`, `us-east4`, `europe-west4`, `southamerica-east1`.
- **VPCs**: 1 central `routing-vpc`, 4 regional `onprem-vpc`s.
- **Connectivity**: HA VPN tunnels between routing and on-prem VPCs.
- **Routing**: NCC Hub and Spokes with site-to-site data transfer enabled.

### Usage
To set up the environment:
```bash
cd poc1
./setup.sh
```
To tear down the environment:
```bash
cd poc1
./teardown.sh
```

## PoC 2: Dual Gateway in Single Region
This PoC simulates connecting two separate on-premises environments in the same region to a central routing VPC, using different ASNs.

### Topology
- **Regions**: `us-west1`, `asia-southeast1`.
- **VPCs**: 1 central `routing-vpc`, 3 `onprem-vpc`s (1 in US, 2 in Asia).
- **Asia Region Detail**: Two separate on-prem VPCs in `asia-southeast1` connect to two separate VPN gateways in the routing VPC in the same region.
- **Routing**: NCC Hub and Spokes with site-to-site data transfer enabled.

### Usage
To set up the environment:
```bash
cd poc2
./setup.sh
```
To tear down the environment:
```bash
cd poc2
./teardown.sh
```

---
*Note: Scripts are designed to be idempotent and will skip creation of resources that already exist.*
