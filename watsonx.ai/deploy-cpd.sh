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

OPERATOR_NAMESPACE="$(cat $PARAMETERS | jq -r .cpd.namespace.cpd_operator)"
INSTANCE_NAMESPACE="$(cat $PARAMETERS | jq -r .cpd.namespace.cpd_operands)"
CERT_MGR_NAMESPACE="$(cat $PARAMETERS | jq -r .cpd.namespace.cert_manager)"
SCHEDULING_SVC_NAMESPACE="$(cat $PARAMETERS | jq -r .cpd.namespace.scheduling_service)"
LICENSE_SVC_NAMESPACE="$(cat $PARAMETERS | jq -r .cpd.namespace.license_service)"
BIN_DIR="$(cat $PARAMETERS | jq -r .directories.bin_dir)"
API_SERVER="$(cat $PARAMETERS | jq -r .cluster.api_server)"
OCP_USERNAME="$(cat $PARAMETERS | jq -r .cluster.username)"
OCP_PASSWORD="$(cat $PARAMETERS | jq -r .cluster.password)"
export STG_CLASS_FILE="$(cat $PARAMETERS | jq -r .cluster.storageclass.file)"
export STG_CLASS_BLOCK="$(cat $PARAMETERS | jq -r .cluster.storageclass.block)"
export VERSION="$(cat $PARAMETERS | jq -r .cpd.version)"
export IBM_ENTITLEMENT_KEY="$(cat $PARAMETERS | jq -r .cpd.ibm_entitlement_key)"

###
# Confirm oc cli and log into the OpenShift cluster
if [[ ! -f ${BIN_DIR}/oc ]]; then
    echo "ERROR: oc tool not installed at ${BIN_DIR}/oc"
    exit 1
else
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
fi

###
# Confirm cpd-cli is installed and login to OpenShift with cpd-cli
if [[ ! -f ${BIN_DIR}/cpd-cli ]]; then
    echo "ERROR: cpd-cli not installed at ${BIN_DIR}/cpd-cli"
    exit 0
else
    # Restart cpd-cli container
    ${BIN_DIR}/cpd-cli manage restart-container

    # Log into openshift from container
    ${BIN_DIR}/cpd-cli manage login-to-ocp --server "${API_SERVER}" -u $OCP_USERNAME -p $OCP_PASSWORD

    if [[ $? != 0 ]]; then
        echo "ERROR: Failed to log into the OpenShift cluster via the cpd cli tool"
        exit 1
    fi
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

###
# Create cert manager and licensing services
echo
echo "**** Creating cert manager and licensing services"
${BIN_DIR}/cpd-cli manage apply-cluster-components --release=${VERSION} \
    --license_acceptance=true \
    --cert_manager_ns=${CERT_MGR_NAMESPACE} \
    --scheduler_ns=${SCHEDULING_SVC_NAMESPACE}


${BIN_DIR}/cpd-cli manage authorize-instance-topology --cpd_operator_ns=${OPERATOR_NAMESPACE} --cpd_instance_ns=${INSTANCE_NAMESPACE}
${BIN_DIR}/cpd-cli manage setup-instance-topology --release=${VERSION} --cpd_operator_ns=${OPERATOR_NAMESPACE} --cpd_instance_ns=${INSTANCE_NAMESPACE} --block_storage_class=${STG_CLASS_BLOCK}  --license_acceptance=true

###
# Create catalog sources and create subscription for cpd operator
echo
echo "**** Creating catalog soruces and subscription for cpd operator"
${BIN_DIR}/cpd-cli manage apply-olm --release=${VERSION} --components=cpd_platform --cpd_operator_ns=${OPERATOR_NAMESPACE}

if [[ $? != 0 ]]; then
    echo "ERROR: Failed to apply cpfs,cpd_platform catalog or subscription"
    exit 1
fi

###
# Create the cpd platform instance
echo
echo "**** Creating the CPD platform operand"
${BIN_DIR}/cpd-cli manage apply-cr --release=${VERSION} --components=cpd_platform  --license_acceptance=true --cpd_instance_ns=${INSTANCE_NAMESPACE} --file_storage_class=${STG_CLASS_FILE} --block_storage_class=${STG_CLASS_BLOCK}

if [[ $? != 0 ]]; then
    echo "ERROR: Failed to apply cpd_platform"
    exit 1
fi

###
# Enable CSV injector
echo
echo "**** Enabling the CSV injector"
${BIN_DIR}/oc patch namespacescope common-service --type='json' -p='[{"op":"replace", "path": "/spec/csvInjector/enable", "value":true}]' -n ${OPERATOR_NAMESPACE}

