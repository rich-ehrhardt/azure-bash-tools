#!/bin/bash
#################################
#
# Script to destroy an Azure Red Hat OpenShift cluster
# and associated components created with the matching
# script.
#
# Author: R.Ehrhardt
#

function usage() {
    echo "Destroys an ARO cluster using a supplied parameters file"
    echo 
    echo "Usage: ${0} [-p PARAMETER_FILE] [-d] [-h]"
    echo "  options"
    echo "  -p    the filename and path to the file containing the parameters. "
    echo "        Refer documentation for content details."
    echo "        default filename is parameters.json in the current path"
    echo "  -d    flag to delete the resource group"
    echo "  -h    display this help"
}

function get-parameter() {
    echo $(cat $PARAMETER_FILE | jq -r ".${1}")
}


while getopts ":p:hd" option; do
    case $option in
        h)   # Display help
            usage
            exit 1;;
        p)   # Set parameter file
            PARAMETER_FILE=$OPTARG;;
        d)   # Delete the resource group as well
            DELETE_RESOURCE_GROUP=true;;
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
DELETE_RESOURCE_GROUP=false

# Set default subscription
if [[ ! $( az account list --query "[].id" | grep $(get-parameter subscriptionId) ) ]] ; then
    echo "ERROR: Subscription id not found in available subscriptions"
    exit 1
else
    echo "INFO: Setting default subscription to $(get-parameter subscriptionId)"
    az account set --subscription $(get-parameter subscriptionId) 1> /dev/null
fi

# Delete the cluster
if [[ $(az aro list -g $(get-parameter resourceGroup) --query "[?name == '$(get-parameter cluster.name)']" -o tsv ) ]]; then
    echo "INFO: Destroying Azure Red Hat OpenShift cluster $(get-parameter cluster.name) in $(get-parameter resourceGroup)"
    az aro delete -y \
        --name $(get-parameter cluster.name) \
        --resource-group $(get-parameter resourceGroup) 
else
    echo "INFO: Azure Red Hat OpenShift cluster $(get-parameter cluster.name) does not exist in $(get-parameter resourceGroup)"
fi

# Delete the VNet
if [[ $(az network vnet list -g $(get-parameter resourceGroup) --query "[?name == '$(get-parameter network.vnetName)']" -o tsv ) ]]; then
    echo "INFO: Destroying virtual network $(get-parameter network.vnetName) in $(get-parameter resourceGroup)"
    NETWORK_ID=$(az network vnet list -g $(get-parameter resourceGroup) --query "[?name == '$(get-parameter network.vnetName)'].id")
    az network vnet delete \
        --name $(get-parameter network.vnetName) \
        --resource-group $(get-parameter resourceGroup) 1> /dev/null
else
    echo "INFO: Virtual network $(get-parameter network.vnetName) does not exist"
fi

if [[ $DELETE_RESOURCE_GROUP == true ]]; then
    if [[ $(az group list --query "[?name == '$(get-parameter resourceGroup)']" -o tsv) ]]; then
        echo "Destroying resource group $(get-parameter resourceGroup)"
        az group delete -n $(get-parameter resourceGroup) 1> /dev/null
    else
        echo "INFO: Resource group $(get-parameter resourceGroup) does not exist"
    fi
fi

echo "INFO: Destroy completed" 

