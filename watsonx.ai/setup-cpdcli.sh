#!/bin/bash

###
# Confirm jq is installed
if [[ ! $(which jq 2> /dev/null ) ]]; then
    echo "ERROR: jq tool not found"
    exit 1
fi

###
# Get parameters filename
PARAMETERS="$1"

BIN_DIR="$(cat $PARAMETERS | jq -r .directories.bin_dir)"
TMP_DIR="$(cat $PARAMETERS | jq -r .directories.tmp_dir)"
API_SERVER="$(cat $PARAMETERS | jq -r .cluster.api_server)"
OCP_USERNAME="$(cat $PARAMETERS | jq -r .cluster.username)"
OCP_PASSWORD="$(cat $PARAMETERS | jq -r .cluster.password)"
OC_VERSION="$(cat $PARAMETERS | jq -r .cluster.version)"
VERSION="$(cat $PARAMETERS | jq -r .cpd.version)"
CPD_EDITION="$(cat $PARAMETERS | jq -r .cpd.edition)"
IBM_ENTITLEMENT_KEY="$(cat $PARAMETERS | jq -r .cpd.ibm_entitlement_key)"
CPDCLI_VERSION="$(cat $PARAMETERS | jq -r .cpd.cpdcli_version)"

###
# Confirm oc cli and log into the OpenShift cluster
if [[ ! -f ${BIN_DIR}/oc ]]; then
    echo "INFO: oc not found. Will install"

    ARCH=$(uname -m)
    OC_FILETYPE="linux"
    OC_URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_VERSION}/openshift-client-${OC_FILETYPE}.tar.gz"

    curl -sLo $TMP_DIR/openshift-client.tgz $OC_URL

    if ! error=$(tar xzf ${TMP_DIR}/openshift-client.tgz -C ${TMP_DIR} oc 2>&1) ; then
        echo "ERROR: Unable to extract oc from tar file"
        exit 1
    fi

    if ! error=$(mv ${TMP_DIR}/oc ${BIN_DIR}/oc 2>&1) ; then
        echo "ERROR: Unable to move oc to $BIN_DIR"
        exit 1
    fi
else
    echo "INFO: oc found. Skipping install"
fi

if [[ ! $(${BIN_DIR}/oc status 2> /dev/null) ]]; then
    echo "**** Trying to log into the OpenShift cluster from command line"
    ${BIN_DIR}/oc login "${API_SERVER}" -u $OCP_USERNAME -p $OCP_PASSWORD --insecure-skip-tls-verify=true

    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to log into OpenShift cluster"
        exit 1
    fi
else
    echo
    echo "**** Already logged into the OpenShift cluster"
fi


###
# Confirm cpd-cli is installed and login to OpenShift with cpd-cli
if [[ ! -f ${BIN_DIR}/cpd-cli ]]; then
    echo "INFO: cpd-cli not found. Installing"

    # Download the cpdcli package
    echo "INFO: Downloading cpd-cli package https://github.com/IBM/cpd-cli/releases/download/v${CPDCLI_VERSION}/cpd-cli-linux-${CPD_EDITION}-${CPDCLI_VERSION}.tgz"
    curl -sLo $TMP_DIR/cpd-cli-linux-${CPD_EDITION}.tgz https://github.com/IBM/cpd-cli/releases/download/v${CPDCLI_VERSION}/cpd-cli-linux-${CPD_EDITION}-${CPDCLI_VERSION}.tgz

    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to download cpd-cli package https://github.com/IBM/cpd-cli/releases/download/v${CPDCLI_VERSION}/cpd-cli-linux-${CPD_EDITION}-${CPDCLI_VERSION}.tgz"
        exit 1
    fi

    # Unpack cpd-cli
    tar xzf $TMP_DIR/cpd-cli-linux-${CPD_EDITION}.tgz -C $TMP_DIR

    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to unpack cpd-cli package $TMP_DIR/cpd-cli-linux-${CPD_EDITION}.tgz"
        exit 1
    fi

    # Copy binary file and plugins
    cd ${TMP_DIR}/cpd-cli-linux-${CPD_EDITION}-${CPDCLI_VERSION}*
    if [[ $USER != "root" ]]; then
        sudo cp -r * ${BIN_DIR}/
    else
        cp -r * ${BIN_DIR}/
    fi

fi

# Restart cpd-cli container
${BIN_DIR}/cpd-cli manage restart-container

# Log into openshift from container
${BIN_DIR}/cpd-cli manage login-to-ocp --server "${API_SERVER}" -u $OCP_USERNAME -p $OCP_PASSWORD

if [[ $? != 0 ]]; then
    echo "ERROR: Failed to log into the OpenShift cluster via the cpd cli tool"
    exit 1
fi


###
# Use cpd cli to update the global pull secret
echo
echo "**** Creating the global pull secret"
${BIN_DIR}/cpd-cli manage add-icr-cred-to-global-pull-secret --entitled_registry_key=${IBM_ENTITLEMENT_KEY}

if [[ $? != 0 ]]; then
    echo "ERROR: Failed to update the global secret"
    exit 1
fi


