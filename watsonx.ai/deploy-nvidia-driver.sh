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
if [[ ! $(${BIN_DIR}/oc get namespace nvidia-gpu-operator 2> /dev/null) ]]; then
    echo "Creating namespace for NVidia Driver"
    ${BIN_DIR}/oc new-project nvidia-gpu-operator
    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to create new namespace"
        exit 1
    fi
else
    echo "Nvidia driver namespace already exists"
fi

#####
# Create operator group
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create operator group"
    exit 1
fi

#####
# Get channel details
CHANNEL=$(oc get packagemanifest gpu-operator-certified -n openshift-marketplace -o jsonpath='{.status.defaultChannel}')
if [[ $? != 0 ]]; then
    echo "ERROR: Unable get package manifest default channel"
    exit 1
fi

PACKAGE=$(oc get packagemanifests/gpu-operator-certified -n openshift-marketplace -ojson | jq -r '.status.channels[] | select(.name == "'$CHANNEL'") | .currentCSV')
if [[ $? != 0 ]]; then
    echo "ERROR: Unable get package manifest CSV"
    exit 1
fi

#####
# Create subscription
cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: "$CHANNEL"
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: "$PACKAGE"
EOF

######
# Wait for subscription to bind to CSV
wait_for_subscription nvidia-gpu-operator gpu-operator-certified

#####
# Create the cluster policy
cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  migManager:
    enabled: true
  operator:
    defaultRuntime: crio
    initContainer: {}
    runtimeClass: nvidia
    deployGFD: true
  dcgm:
    enabled: true
  gfd: {}
  dcgmExporter:
    config:
      name: ''
    serviceMonitor:
      enabled: true
  driver:
    licensingConfig:
      nlsEnabled: false
      configMapName: ''
    certConfig:
      name: ''
    kernelModuleConfig:
      name: ''
    repoConfig:
      configMapName: ''
    virtualTopology:
      config: ''
    enabled: true
    use_ocp_driver_toolkit: true
  devicePlugin: {}
  mig:
    strategy: single
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: 'true'
  nodeStatusExporter:
    enabled: true
  daemonsets: {}
  toolkit:
    enabled: true
EOF

####
# Wait for cluster policy to be available
count=0;
while [[ $(${BIN_DIR}/oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}{"\n"}') != "ready" ]]; do
    echo "INFO: Waiting for Cluster Policy to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC to be ready"
        exit 1
    fi
done
