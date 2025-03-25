# Deploy IBM Fusion on an OpenShift cluster with local storage cluster

This script will deploy the operators and operands for IBM Fusion, label nodes and create a storage cluster locally on the OpenShift cluster.

At least 1 worker node of 16 vCPU and 64GB of RAM must be available in 3 regions.

## Instructions

1. Edit the `parameters-template.json` file to suit the cluster credentials and specification.

2. Run the script
```shell
./deploy-fusion.sh parameters.json
```

Where `parameters.json` is the name of your edited `parameters.json` file.