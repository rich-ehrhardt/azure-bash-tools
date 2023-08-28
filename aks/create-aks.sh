#!/bin/bash

source ./common.sh

# Set defaults
if [[ -z $TAGS ]]; then TAGS="created-by=$(az account show --query 'user.name' -o tsv)"; fi
if [[ -z $SUBSCRIPTION_ID ]]; then SUBSCRIPTION_ID="$(az account show --query "id" -o tsv)"; fi
if [[ -z $NODE_COUNT ]]; then NODE_COUNT=3; fi
if [[ -z $VNET_NAME ]]; then VNET_NAME="vnet"; fi
if [[ -z $VNET_CIDR ]]; then VNET_CIDR="10.0.0.0/20"; fi
if [[ -z $AKS_SUBNET_NAME ]]; then AKS_SUBNET_NAME="aks-subnet"; fi
if [[ -z $AKS_SUBNET_CIDR ]]; then AKS_SUBNET_CIDR="10.0.0.0/22"; fi
if [[ -z $SERVICE_CIDR ]]; then SERVICE_CIDR="10.1.0.0/16"; fi
if [[ -z $DNS_SERVICE_IP ]]; then DNS_SERVICE_IP="10.1.0.10"; fi
if [[ -z $DOCKER_BRIDGE_ADDRESS ]]; then DOCKER_BRIDGE_ADDRESS="172.17.0.1/16"; fi

# Get resource group
if [[ -z $RESOURCE_GROUP ]]; then

    existing_rg=""
    while [[ $existing_rg == "" ]]; do
        echo -n "Existing resource group? [Y] : "
        read input
        input=$(echo ${input:0:1} | tr '[:upper:]' '[:lower:]' )
        case $input in
            '') existing_rg="yes";;
            'y') existing_rg="yes";;
            'n') existing_rg="no";;
            *) echo "Unknown input";;
        esac
    done

    if [[ $existing_rg == "yes" ]]; then
        IFS=$'\n'
        read -r -d '' -a RGS < <(az group list --query '[].name' -o tsv)
        PS3="Select the resource group : "
        RG=$(menu "${RGS[@]}")
    else
        echo -n "Enter the name of the resource group to create : "
        read RG
    fi

    RESOURCE_GROUP=$RG
else
    echo "INFO: Resource group is set to $RESOURCE_GROUP"
fi

# Get the deployment location
if [[ -z $LOCATION ]]; then
    same_location=""
    while [[ $same_location == "" ]]; do
        echo -n "Use the same location as resource group ($(az group show -n rbe-rg --query "location" -o tsv))? [Y] :"
        read input
        input=$(echo ${input:0:1} | tr '[:upper:]' '[:lower:]' )
        case $input in
            '') same_location="yes";;
            'y') same_location="yes";;
            'n') same_location="no";;
            *) echo "Unknown input";;
        esac
    done

    if [[ $same_location == "yes" ]]; then
        LOCATION="$(az group show -n rbe-rg --query "location" -o tsv)"
    else
        LOCATION=$(get-location)
    fi
else
    echo "INFO: Location set to $LOCATION"
fi

# Get VM size
if [[ -z $VM_SIZE ]]; then
    echo -n "Enter the VM Size to use for the cluster nodes [Standard_D2s_v4] : "
    read input
    case $input in 
        '') VM_SIZE="Standard_D2s_v4";;
        *)  VM_SIZE=$input;;
    esac
else
    echo "INFO: VM Size is set to $VM_SIZE"
fi

# Get the Cluster name
if [[ -z $AKS_CLUSTER ]]; then
    DEFAULT="${RESOURCE_GROUP}-aks"
    echo -n "Enter the name for the AKS cluster [$DEFAULT] : "
    read input
    case $input in 
        '') AKS_CLUSTER="$DEFAULT";;
        *)  AKS_CLUSTER=$input;;
    esac
else
    echo "INFO: AKS Cluster name is set to $AKS_CLUSTER"
fi

# Set the subscription
if [[ $(az account show --query "id" -o tsv) != $SUBSCRIPTION_ID ]]; then
    echo "INFO: Setting subscription to $SUBSCRIPTION_ID"
else
    echo "INFO: Using existing subscription"
fi

# Create the resource group if it does not exist
if [[ -z $(az group list -o table | grep $RESOURCE_GROUP) ]]; then
    echo "INFO: Creating resource group $RESOURCE_GROUP"
    az group create \
        --name $RESOURCE_GROUP \
        --location $LOCATION \
        --tags "$TAGS"

    if (( $? != 0 )); then
        echo "ERROR: Unable to create resource group"
        exit 1
    else
        echo "INFO: Successfully created resource group $RESOURCE_GROUP"
    fi
else
    echo "INFO: Resource group $RESOURCE_GROUP already exists"
fi

# Create VNet
if [[ -z $(az network vnet list --query "[].{Name:name, ResourceGroup:resourceGroup}" -o table | grep $VNET_NAME | grep $RESOURCE_GROUP) ]]; then
    echo "INFO: Creating virtual network $VNET_NAME"
    az network vnet create -n $VNET_NAME -g $RESOURCE_GROUP \
        --address-prefixes "${VNET_CIDR}" \
        --subnet-name "${AKS_SUBNET_NAME}" \
        --subnet-prefixes "${AKS_SUBNET_CIDR}" \
        --tags "$TAGS"

    if (( $? != 0 )); then
        echo "ERROR: Unable to create virtual network"
        exit 1
    else
        echo "INFO: Successfully created virtual network $VNET_NAME"
    fi
else
    echo "INFO: Virtual network $VNET_NAME already exists"
fi

AKS_SUBNET_ID=$(az network vnet subnet show -n $AKS_SUBNET_NAME -g $RESOURCE_GROUP --vnet-name $VNET_NAME --query "id" -o tsv)

# Create the AKS cluster
if [[ -z $(az aks list -g $RESOURCE_GROUP -o table | grep $AKS_CLUSTER ) ]]; then
    echo "INFO: Creating AKS cluster $AKS_CLUSTER"
    az aks create \
        --name $AKS_CLUSTER \
        --resource-group $RESOURCE_GROUP \
        --location $LOCATION \
        --node-count $NODE_COUNT \
        --node-vm-size $VM_SIZE \
        --service-cidr $SERVICE_CIDR \
        --dns-service-ip $DNS_SERVICE_IP \
        --docker-bridge-address $DOCKER_BRIDGE_ADDRESS \
        --network-plugin azure \
        --vnet-subnet-id $AKS_SUBNET_ID \
        --enable-encryption-at-host \
        --enable-managed-identity \
        --generate-ssh-keys \
        --tags "$TAGS"

    if (( $? != 0 )); then
        echo "ERROR: Unable to create AKS cluster $AKS_CLUSTER"
        exit 1
    else
        echo "INFO: Successfully created AKS cluster $AKS_CLUSTER"
    fi
else
    echo "INFO: AKS cluster $AKS_CLUSTER already exists"
fi