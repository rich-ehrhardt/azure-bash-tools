#!/bin/bash
#
# Builds watsonx.ai on an existing cluster
#
# Prerequisities
# - Linux x86_64 server
# - sudo access without password if running as non-root
# - podman installed on server
# - OpenShift cluster with Fusion or ODF storage cluster configured

###
# Confirm jq is installed
if [[ ! $(which jq 2> /dev/null ) ]]; then
    echo "ERROR: jq tool not found"
    exit 1
fi

###
# Get parameters filename
PARAMETERS="$1"

if [[ -z $PARAMETERS ]]; then
    echo "ERROR: Parameter filename missing"
    exit 1
fi

### Install and setup cpd, oc cli tools
echo "*******************************************"
echo "INFO: Setting up CPD CLI"
echo "*******************************************"
/bin/bash ./setup-cpdcli.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Setup of CPD CLI was unsuccessful"
    exit 1
fi

### Deploy Foundation Services
echo "*******************************************"
echo "INFO: Deploying foundation services"
echo "*******************************************"
/bin/bash  ./deploy-cpd.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Deployment of Foundation services was unsuccessful"
    exit 1
fi

## Deploy Node Feature Discovery Tool
echo "*******************************************"
echo "INFO: Deploying Node Feature Discovery Tool"
echo "*******************************************"
/bin/bash ./deploy-nfdt.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Deployment of NFDT was unsuccessful"
    exit 1
fi

## Deploy GPU drivers
echo "*******************************************"
echo "INFO: Deploying GPU Drivers"
echo "*******************************************"
/bin/bash ./deploy-nvidia-driver.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Deployment of GPU drivers was unsuccessful"
    exit 1
fi

## Deploy Red Hat OpenShift AI
echo "*******************************************"
echo "INFO: Deploying Red Hat OpenShift AI"
echo "*******************************************"
/bin/bash ./deploy-rhoai.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Deployment of Red Hat OpenShift AI was unsuccessful"
    exit 1
fi

## Deploy watsonx.ai
echo "*******************************************"
echo "INFO: Deploying watsonx.ai"
echo "*******************************************"
/bin/bash ./deploy-watsonx-ai.sh $PARAMETERS

if [[ $? != 0 ]]; then
    echo "ERROR: Deployment of watsonx.ai was unsuccessful"
    exit 1
fi