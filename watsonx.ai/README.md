# Deploy watsonx.ai on an existing cluster

## Prequisites

- An existing OpenShift 4.x cluster 
- IBM Fusion / ODF installed on cluster (you can use the fusion scripts in this repo if needed)
- CLI tools installed
    - podman
    - jq
- passwordless sudo if running as non-root

> Note that these scripts are designed to be run on a Linux distribution

## Preparation

Copy the `parameters-template.json` file to another filename and edit. In particular, add the existing cluster API and credentials in addition to your IBM entitlement key and the home directory for the user (the cpd directory).

## Execution

Once the parameters file is created, run the `build-watsonx.sh` script as follows.
```shell
./build-watsonx.sh parameters.json
```