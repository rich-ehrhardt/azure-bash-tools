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
STORAGE_SIZE="$(cat $PARAMETERS | jq -r .fusion.storageSize)"
IBM_ENTITLEMENT_KEY="$(cat $PARAMETERS | jq -r .cpd.ibm_entitlement_key)"

###
# Set defaults
if [[ $USER != "root" ]]; then SUDO="sudo "; fi

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
    echo "INFO: oc not found. Will install"

    ARCH=$(uname -m)
    OC_FILETYPE="linux"
    OC_URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/stable-${OC_VERSION}/openshift-client-${OC_FILETYPE}.tar.gz"

    echo "Downloading $OC_URL"
    curl -sLo $TMP_DIR/openshift-client.tgz $OC_URL

    if ! error=$(tar xzf ${TMP_DIR}/openshift-client.tgz -C ${TMP_DIR} oc 2>&1) ; then
        echo "ERROR: Unable to extract oc from tar file"
        exit 1
    fi

    if ! error=$(${SUDO} mv ${TMP_DIR}/oc ${BIN_DIR}/oc 2>&1) ; then
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
# Create the entitlement credentials secret

if [[ $(oc get secret/pull-secret -n openshift-config -ojson | jq -r '.data[".dockerconfigjson"]' | base64 -d | jq .auths.\"cp.icr.io\" 2> /dev/null) != "null" ]]; then
    echo "Pull secret for cp.icr.io already exists on cluster"
else
    echo "Pull secret for cp.icr.io not found. Creating"

    # Create base64 encoded entitlement key credentials
    CREDENTIALS="$(echo -n cp:${IBM_ENTITLEMENT_KEY} | base64 -w0)"

    # Create the authority.json file
    echo "{\"auth\":\"${CREDENTIALS}\"}" > ${TMP_DIR}/authority.json

    # Create new authority file
    ${BIN_DIR}/oc get secret/pull-secret -n openshift-config -ojson | jq -r '.data[".dockerconfigjson"]' | base64 -d  | jq '.[]."cp.icr.io" += input' - ${TMP_DIR}/authority.json > ${TMP_DIR}/temp_config.json

    # Set the new secret
    ${BIN_DIR}/oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=${TMP_DIR}/temp_config.json

    # Clean up the files
    rm ${TMP_DIR}/authority.json ${TMP_DIR}/temp_config.json

fi

###
# Create the IBM Fusion operator
cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ibm-spectrum-fusion-ns
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: isf-og
  namespace: ibm-spectrum-fusion-ns
spec:
  targetNamespaces:
  -  ibm-spectrum-fusion-ns
  upgradeStrategy: Default
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ibm-operator-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image:  icr.io/cpopen/ibm-operator-catalog:latest
  displayName: IBM Operator Catalog
  publisher: IBM
  updateStrategy:
   registryPoll:
    interval: 45m
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: isf-operator
  namespace: ibm-spectrum-fusion-ns
spec:
  channel: v2.0
  name: isf-operator
  sourceNamespace: openshift-marketplace
  source: ibm-operator-catalog
  installPlanApproval: Automatic
EOF

###
# wait for subscription to bind
wait_for_subscription ibm-spectrum-fusion-ns isf-operator

###
# Accept the license
cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: prereq.isf.ibm.com/v1
kind: SpectrumFusion
metadata:
  name: spectrumfusion
  namespace: ibm-spectrum-fusion-ns
spec:
  license:
    accept: true
EOF

##
# Wait for CR to create
count=0;
while [[ $(${BIN_DIR}/oc get SpectrumFusion -n ibm-spectrum-fusion-ns spectrumfusion -o jsonpath='{.status.status}{"\n"}') != "Completed" ]]; do
    echo "INFO: Waiting for SpectrumFusion to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC Initialization to be ready"
        exit 1
    fi
done

####
# Deploy data foundation service
cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: service.isf.ibm.com/v1
kind: FusionServiceInstance
metadata:
  name:  odfmanager
  namespace: ibm-spectrum-fusion-ns
spec:
  creator: User
  doInstall: true
  parameters:
  - name: namespace
    provided: false
    value: openshift-storage
  - name: creator
    provided: false
    value: Fusion
  - name: backingStorageType
    provided: true
    value: Local
  - name: autoUpgrade
    provided: false
    value: "true"
  - name: enableLVMStorage
    provided: true
    value: "false"
  serviceDefinition: data-foundation-service
  triggerUpdate: false
EOF

### Wait for service to start
count=0;
while [[ $(${BIN_DIR}/oc get FusionServiceInstance -n ibm-spectrum-fusion-ns odfmanager -o jsonpath='{.status.installStatus.status}{"\n"}') != "Completed" ]]; do
    echo "INFO: Waiting for Data Foundation to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC Initialization to be ready"
        exit 1
    fi
done

###
# Label nodes

# Get list of worker nodes
echo "INFO: Getting list of worker nodes"
NODES=( $(${BIN_DIR}/oc get nodes | grep worker | awk '{print $1}') )

# Confirm that there are 3 nodes available
if (( $(echo ${#NODES[@]}) < 3  )); then
    echo "ERROR: Insufficient nodes for storage cluster. Must have at least 3 nodes available"
    exit 1
fi

# Get the size and zone of each node in array
echo "INFO: Getting node details"
for node in ${NODES[@]}; do
    cpu=$(${BIN_DIR}/oc get node $node -o json | jq -r '.status.capacity.cpu')
    mem=$(${BIN_DIR}/oc get node $node -o json | jq -r '.status.capacity.memory')
    zone=$(${BIN_DIR}/oc get machine -n openshift-machine-api | grep $node | awk '{print $5}')
    if (( $cpu > 15 )); then
        if [[ -z $(${BIN_DIR}/oc get node ${ODF_NODES_ZONE1[1]//\"/} -o json | jq '.metadata.labels' | grep "cluster.ocs.openshift.io") ]]; then
        labelled="false"
        else
        labelled="true"
        fi
        jq -n \
        --arg name "$node" \
        --arg cpu $cpu \
        --arg mem $mem \
        --arg zone $zone \
        --arg labelled $labelled \
        '{name: $name, cpu: $cpu, mem: $mem, zone: $zone, labelled: $labelled}'
    fi
done | jq -n '.nodes |= [inputs]' > ${TMP_DIR}/node-details.json

NODE_DETAIL="$(cat ${TMP_DIR}/node-details.json)"

# Check enough nodes of 16 CPU or higher available
echo "INFO: Checking size of nodes"
if (( $( echo $NODE_DETAIL | jq '.nodes | length' ) < 3  )); then
    echo "ERROR: Insufficient nodes of sufficient size available for storage cluster"
    echo "ERROR: Minimum of 3 nodes with 16 CPU or more required"
    exit 1
fi

# Choose 1 node from each availability zone
ZONE1_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "1") | select(.labelled == "true") | .name' ) )
if (( ${#ZONE1_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE1_LABELLED_NODES[@]}; do
        echo "INFO: Using existing labelled node $node"
    done
else
    echo "INFO: Checking sufficiently sized node available availability zone 1"
    ODF_NODES_ZONE1=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "1") | .name') )
    if (( ${#ODF_NODES_ZONE1[@]} < 1 )); then
        echo "ERROR: Insufficient nodes in availability zone 1 of sufficient size for storage cluster"
        exit 1
    else
        echo "INFO: ${ODF_NODES_ZONE1[0]} is of sufficient size in availability zone 1 and will be labelled for ODF"
        echo "INFO: Labelling ${ODF_NODES_ZONE1[0]//\"/} as ODF node for availability zone 1"
        ${BIN_DIR}/oc label node ${ODF_NODES_ZONE1[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
    fi
fi

ZONE2_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "2") | select(.labelled == "true") | .name' ) )
if (( ${#ZONE2_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE2_LABELLED_NODES[@]}; do
        echo "INFO: Using existing labelled node $node"
    done
else
    ODF_NODES_ZONE2=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "2") | .name') )
    if (( ${#ODF_NODES_ZONE2[@]} < 1 )); then
        echo "ERROR: Insufficient nodes in availability zone 2 of sufficient size for storage cluster"
        exit 1
    else
        echo "INFO: ${ODF_NODES_ZONE2[0]//\"/} is of sufficient size in availability zone 2 and will be labelled for ODF"
        echo "INFO: Labelling ${ODF_NODES_ZONE2[0]//\"/} as ODF node for availability zone 2"
        ${BIN_DIR}/oc label node ${ODF_NODES_ZONE2[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
    fi
fi

ZONE2_LABELLED_NODES=( $(echo $NODE_DETAIL| jq '.nodes[] | select(.zone == "2") | select(.labelled == "true") | .name' ) )
if (( ${#ZONE2_LABELLED_NODES[@]} > 0 )); then    
    for node in ${ZONE2_LABELLED_NODES[@]}; do
        echo "INFO: Using existing labelled node $node"
    done
else
    ODF_NODES_ZONE3=( $(echo $NODE_DETAIL | jq '.nodes[] | select(.zone == "3") | .name') )
    if (( ${#ODF_NODES_ZONE2[@]} < 1 )); then
        echo "ERROR: Insufficient nodes in availability zone 3 of sufficient size for storage cluster"
        exit 1
    else
        echo "INFO: ${ODF_NODES_ZONE2[0]//\"/} is of sufficient size in availability zone 3 and will be labelled for ODF"
        echo "INFO: Labelling ${ODF_NODES_ZONE3[0]//\"/} as ODF node for availability zone 3"
        ${BIN_DIR}/oc label node ${ODF_NODES_ZONE3[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
    fi
fi

#####
# Create the storage cluster
if [[ -z $(${BIN_DIR}/oc get storagecluster -n openshift-storage ocs-storagecluster) ]]; then
    echo "INFO: Creating storage cluster ocs-storagecluster"
    SC_NAME=$(${BIN_DIR}/oc get sc | grep disk.csi.azure.com | awk '{print$1}')
    cat << EOF | oc apply -f -
apiVersion: v1
items:
- apiVersion: ocs.openshift.io/v1
  kind: StorageCluster
  metadata:
    name: ocs-storagecluster
    namespace: openshift-storage
  spec:
    arbiter: {}
    encryption:
      clusterWide: true
      enable: true
      keyRotation:
        schedule: '@weekly'
      kms: {}
    externalStorage: {}
    managedResources:
      cephBlockPools: {}
      cephCluster: {}
      cephConfig: {}
      cephDashboard: {}
      cephFilesystems:
        dataPoolSpec:
          application: ""
          erasureCoded:
            codingChunks: 0
            dataChunks: 0
          mirroring: {}
          quotas: {}
          replicated:
            size: 0
          statusCheck:
            mirror: {}
      cephNonResilientPools:
        count: 1
        resources: {}
        volumeClaimTemplate:
          metadata: {}
          spec:
            resources: {}
          status: {}
      cephObjectStoreUsers: {}
      cephObjectStores: {}
      cephRBDMirror:
        daemonCount: 1
      cephToolbox: {}
    mirroring: {}
    storageDeviceSets:
    - config: {}
      count: 1
      dataPVCTemplate:
        metadata: {}
        spec:
          accessModes:
          - ReadWriteOnce
          resources:
            requests:
              storage: ${STORAGE_SIZE}
          storageClassName: ${SC_NAME}
          volumeMode: Block
        status: {}
      name: fusion-storage
      placement: {}
      preparePlacement: {}
      replica: 3
      resources: {}
EOF
else
    echo "INFO: Using existing storage cluster"
fi

######
# Wait for storage cluster to become available
count=0
while [[ $(${BIN_DIR}/oc get StorageCluster ocs-storagecluster -n openshift-storage --no-headers -o custom-columns='phase:status.phase') != "Ready" ]]; do
    echo "INFO: Waiting for storage cluster to become available. Waited $count minutes. Will wait up to 30 minutes"
    sleep 60
    count=$(( $count + 1 ))
    if (( $count > 30 )); then
        echo "ERROR: Timeout waiting for cluster operators to be available"
        exit 1;
    fi
done

echo "Fusion successfully installed on cluster"