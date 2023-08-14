#!/bin/bash
#################################
#
# Script to deploy an Azure Red Hat OpenShift cluster
#
# Author: R.Ehrhardt
#

function usage() {
    echo "Creates an ARO cluster using a supplied parameters file"
    echo 
    echo "Usage: ${0} [-p PARAMETER_FILE]"
    echo "  options"
    echo "  -p    the filename and path to the file containing the parameters. "
    echo "        Refer documentation for content details."
    echo "        default filename is parameters.json in the current path"
}

function get-parameter() {
    echo $(cat $PARAMETER_FILE | jq -r ".${1}")
}


while getopts ":p:h" option; do
    case $option in
        h)   # Display help
            usage
            exit 1;;
        p)   # Set parameter file
            PARAMETER_FILE=$OPTARG;;
        \?) 
            echo "ERROR: Invalid option"
            usage
            exit 1;;
    esac
done

#####
# Set defaults
if [[ -z $PARAMETER_FILE ]]; then 
    PARAMETER_FILE="./parameters.json";
    if [[ ! -f $PARAMETER_FILE ]]; then
        echo "No parameter file specified and default parameters.json does not exist"
        usage
        exit 1
    fi
fi

# Set default subscription
if [[ ! $( az account list --query "[].id" | grep $(get-parameter subscriptionId) ) ]] ; then
    echo "ERROR: Subscription id not found in available subscriptions"
    exit 1
else
    echo "INFO: Setting default subscription to $(get-parameter subscriptionId)"
    az account set --subscription $(get-parameter subscriptionId) 1> /dev/null
fi

# Get user id and format the tag
TAG="created-by=$(az account show --query 'user.name' -o tsv)"

# Create resource group
if [[ ! $(az group list --query "[?name == '$(get-parameter resourceGroup)']" -o tsv ) ]] ; then
    echo "INFO: Creating resource group $(get-parameter resourceGroup)"
    az group create -n $(get-parameter resourceGroup) --location $(get-parameter location) --tags $TAG 1> /dev/null
else
    echo "INFO: Resource group $(get-parameter resourceGroup) already exists"
fi

# Create the VNet
if [[ ! $(az network vnet list -g $(get-parameter resourceGroup) --query "[?name == '$(get-parameter network.vnetName)']" -o tsv ) ]]; then
    echo "INFO: Creating virtual network $(get-parameter network.vnetName) in $(get-parameter resourceGroup)"
    az network vnet create \
        --name $(get-parameter network.vnetName) \
        --address-prefixes $(get-parameter network.vnetCIDR) \
        --resource-group $(get-parameter resourceGroup) \
        --location $(get-parameter location) \
        --tags $TAG 1> /dev/null
else
    echo "INFO: Virtual network $(get-parameter network.vnetName) already exists"
fi

# Create the worker subnet
if [[ ! $(az network vnet subnet list -g $(get-parameter resourceGroup) --vnet-name $(get-parameter network.vnetName) --query "[?name == '$(get-parameter network.workerSubnetName)']" -o tsv ) ]]; then
    echo "INFO: Creating subnet $(get-parameter network.workerSubnetName)"
    az network vnet subnet create \
        --name $(get-parameter network.workerSubnetName) \
        --vnet-name $(get-parameter network.vnetName) \
        --resource-group $(get-parameter resourceGroup) \
        --address-prefixes $(get-parameter network.workerSubnetCIDR) 1> /dev/null
else
    echo "INFO: Subnet $(get-parameter network.workerSubnetName) already exists"
fi

# Create the control subnet
if [[ ! $(az network vnet subnet list -g $(get-parameter resourceGroup) --vnet-name $(get-parameter network.vnetName) --query "[?name == '$(get-parameter network.controlSubnetName)']" -o tsv) ]]; then
    echo "INFO: Creating subnet $(get-parameter network.controlSubnetName)"
    az network vnet subnet create \
        --name $(get-parameter network.controlSubnetName) \
        --vnet-name $(get-parameter network.vnetName) \
        --resource-group $(get-parameter resourceGroup) \
        --address-prefixes $(get-parameter network.controlSubnetCIDR) 1> /dev/null
else
    echo "INFO: Subnet $(get-parameter network.controlSubnetName) already exists"
fi

# Create the cluster
if [[ ! $(az aro list -g $(get-parameter resourceGroup) --query "[?name == '$(get-parameter cluster.name)']" -o tsv ) ]]; then
    echo "INFO: Creating Azure Red Hat OpenShift cluster $(get-parameter cluster.name) in $(get-parameter resourceGroup)"
    az aro create \
        --name $(get-parameter cluster.name) \
        --resource-group $(get-parameter resourceGroup) \
        --location $(get-parameter location) \
        --domain $(get-parameter cluster.domain) \
        --apiserver-visibility $(get-parameter cluster.apiVisibility) \
        --ingress-visibility $(get-parameter cluster.ingressVisibility) \
        --vnet $(get-parameter network.vnetName) \
        --master-subnet $(get-parameter network.controlSubnetName) \
        --worker-subnet $(get-parameter network.workerSubnetName) \
        --master-enc-host true \
        --worker-enc-host true \
        --master-vm-size $(get-parameter cluster.masterSize) \
        --worker-count $(get-parameter cluster.workerQuantity) \
        --worker-vm-size $(get-parameter cluster.workerSize) \
        --version $(get-parameter cluster.version) \
        --pull-secret $(get-parameter cluster.pullSecret) \
        --client-id $(get-parameter servicePrincipal.clientId) \
        --client-secret $(get-parameter servicePrincipal.clientSecret) \
        --tags $TAG 
else
    echo "INFO: Azure Red Hat OpenShift cluster $(get-parameter cluster.name) already exists in $(get-parameter resourceGroup)"
fi

echo "INFO: Installation completed" 

