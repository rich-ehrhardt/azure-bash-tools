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
RHAOI_VERSION="$(cat $PARAMETERS | jq -r .rhoai.version)"

function subscription_status() {
    SUB_NAMESPACE=${1}
    SUBSCRIPTION=${2}

    CSV=$(${BIN_DIR}/oc get subscription -n ${SUB_NAMESPACE} ${SUBSCRIPTION} -o json | jq -r '.status.currentCSV')
    if [[ "$CSV" == "null" ]]; then
        STATUS="PendingCSV"
    else
        STATUS=$(${BIN_DIR}/oc get csv -n ${SUB_NAMESPACE} ${CSV} -o json | jq -r '.status.phase')
    fi
    echo $STATUS
}

function wait_for_subscription() {
    SUB_NAMESPACE=${1}
    export SUBSCRIPTION=${2}
    
    # Set default timeout of 15 minutes
    if [[ -z ${3} ]]; then
        TIMEOUT=15
    else
        TIMEOUT=${3}
    fi

    export TIMEOUT_COUNT=$(( $TIMEOUT * 60 / 30 ))

    count=0;
    while [[ $(subscription_status $SUB_NAMESPACE $SUBSCRIPTION) != "Succeeded" ]]; do
        echo "INFO: Waiting for subscription $SUBSCRIPTION to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
        sleep 30
        count=$(( $count + 1 ))
        if (( $count > $TIMEOUT_COUNT )); then
            echo "ERROR: Timeout exceeded waiting for subscription $SUBSCRIPTION to be ready"
            exit 1
        fi
    done
}

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

#####
# Create namespace if it does not already exist
if [[ ! $(${BIN_DIR}/oc get namespace redhat-ods-operator 2> /dev/null) ]]; then
    echo "Creating namespace for Red Hat OpenShift AI"
    ${BIN_DIR}/oc new-project redhat-ods-operator
    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to create new namespace"
        exit 1
    fi
else
    echo "Red Hat OpenShift AI namespace already exists"
fi

#####
# Create the operator group
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create operator group for Red Hat OpenShift AI"
    exit 1
fi

#####
# Create the subscription
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  name: rhods-operator
  channel: stable-2.13
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  config:
     env:
        - name: "DISABLE_DSC_CONFIG"
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create Red Hat OpenShift AI subscription"
    exit 1
fi

######
# Wait for subscription to bind to CSV
wait_for_subscription redhat-ods-operator rhods-operator

######
# Create the DSC Initialization object
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: dscinitialization.opendatahub.io/v1
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: redhat-ods-applications
  monitoring:
    managementState: Managed
    namespace: redhat-ods-monitoring
  serviceMesh:
    managementState: Removed
  trustedCABundle:
    managementState: Managed
    customCABundle: ""
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create DSC Initialization"
    exit 1
fi

######
# Wait for DSC Initialization to be ready
count=0;
while [[ $(${BIN_DIR}/oc get dscinitialization -o jsonpath='{.items[0].status.phase}{"\n"}') != "Ready" ]]; do
    echo "INFO: Waiting for DSC Initialization to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC Initialization to be ready"
        exit 1
    fi
done

######
# Create the Data Science Cluster
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Removed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
      defaultDeploymentMode: RawDeployment
      serving:
        managementState: Removed
        name: knative-serving
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Managed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF

######
# Wait for DSC to be ready
count=0;
while [[ $(${BIN_DIR}/oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}{"\n"}') != "Ready" ]]; do
    echo "INFO: Waiting for DSC to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC to be ready"
        exit 1
    fi
done

####
# Patch the configmap
TMP_INFERENCE_CONFIG="${TMP_DIR}/inference-config.yaml"
${BIN_DIR}/oc get -n redhat-ods-applications configmap/inferenceservice-config -o yaml > $TMP_INFERENCE_CONFIG
sed -e 's/"domainTemplate": "{{ .Name }}-{{ .Namespace }}.{{ .IngressDomain }}"/"domainTemplate": "example.com"/' -i $TMP_INFERENCE_CONFIG
${BIN_DIR}/oc create -f $TMP_INFERENCE_CONFIG
${BIN_DIR}/oc annotate --overwrite -n redhat-ods-applications configmap/inferenceservice-config opendatahub.io/managed=false
rm $TMP_INFERENCE_CONFIG

