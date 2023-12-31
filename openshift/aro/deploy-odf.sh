#!/bin/bash
# Script to deploy OpenShift Data Foundation onto ARO
#
# Written by:  Rich Ehrhardt
# Email: rich_ehrhardt@au1.ibm.com

function get-parameter() {
    echo $(cat $PARAMETER_FILE | jq -r ".${1}")
}

function subscription_status() {
    SUB_NAMESPACE=${1}
    SUBSCRIPTION=${2}

    CSV=$(oc get subscription -n ${SUB_NAMESPACE} ${SUBSCRIPTION} -o json | jq -r '.status.currentCSV')
    if [[ "$CSV" == "null" ]]; then
        STATUS="PendingCSV"
    else
        STATUS=$(oc get csv -n ${SUB_NAMESPACE} ${CSV} -o json | jq -r '.status.phase')
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

######
# Set defaults
if [[ -z $LICENSE ]]; then LICENSE="decline"; fi
if [[ -z $CLIENT_ID ]]; then CLIENT_ID=""; fi
if [[ -z $CLIENT_SECRET ]]; then CLIENT_SECRET=""; fi
if [[ -z $TENANT_ID ]]; then TENANT_ID=""; fi
if [[ -z $SUBSCRIPTION_ID ]]; then SUBSCRIPTION_ID=""; fi
if [[ -z $WORKSPACE_DIR ]]; then export WORKSPACE_DIR="/tmp/deploy-odf-$(date -u +%Y-%m-%d)"; fi
if [[ -z $TMP_DIR ]]; then export TMP_DIR="${WORKSPACE_DIR}"; fi
if [[ -z $NEW_CLUSTER ]]; then NEW_CLUSTER="no"; fi
if [[ -z $STORAGE_SIZE ]]; then export STORAGE_SIZE="2Ti"; fi
if [[ -z $EXISTING_NODES ]]; then EXISTING_NODES="no"; fi

######
# Create working directories
mkdir -p ${WORKSPACE_DIR}
mkdir -p ${TMP_DIR}

ARO_CLUSTER=$(get-parameter cluster.name)
RESOURCE_GROUP=$(get-paramater resourceGroup)

#######
# Login to cluster
echo "INFO: Logging into OpenShift cluster $ARO_CLUSTER"
API_SERVER=$(az aro list --query "[?contains(name,'$ARO_CLUSTER')].[apiserverProfile.url]" -o tsv)
CLUSTER_PASSWORD=$(az aro list-credentials --name $ARO_CLUSTER --resource-group $RESOURCE_GROUP --query kubeadminPassword -o tsv)
CLUSTER_USERNAME=$(az aro list-credentials --name $ARO_CLUSTER --resource-group $RESOURCE_GROUP --query kubeadminUsername -o tsv)
# Below loop added to allow authentication service to start on new clusters
count=0
while ! oc login $API_SERVER -u $CLUSTER_USERNAME -p $CLUSTER_PASSWORD 1> /dev/null 2> /dev/null ; do
    echo "INFO: Waiting to log into cluster. Waited $count minutes. Will wait up to 15 minutes."
    sleep 60
    count=$(( $count + 1 ))
    if (( $count > 15 )); then
        echo "ERROR: Timeout waiting to log into cluster"
        exit 1;    
    fi
done

#####
# Wait for cluster operators to be available
count=0
while oc get clusteroperators | awk '{print $4}' | grep True; do
    echo "INFO: Waiting on cluster operators to be availabe. Waited $count minutes. Will wait up to 30 minutes."
    sleep 60
    count=$(( $count + 1 ))
    if (( $count > 30 )); then
        echo "ERROR: Timeout waiting for cluster operators to be available"
        exit 1;
    fi
done
echo "INFO: Cluster operators are ready"

##### 
# Obtain cluster id, version and other details
echo "INFO: Obtaining information on cluster"
export CLUSTER_ID=$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)
echo "INFO: CLUSTER_ID = $CLUSTER_ID"

export OCP_VERSION=$(oc version -o json | jq -r '.openshiftVersion' | awk '{split($0,version,"."); print version[1],version[2]}' | sed 's/ /./g')
echo "INFO: OCP_VERSION = $OCP_VERSION"

export CLUSTER_LOCATION=$(az aro list --query "[?contains(name, '$CLUSTER_NAME')].[location]" -o tsv)
echo "INFO: CLUSTER_LOCATION = $CLUSTER_LOCATION"

export IMAGE_SKU=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.image.sku}{"\n"}')
echo "INFO: IMAGE_SKU = $IMAGE_SKU"

export IMAGE_OFFER=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.image.offer}{"\n"}')
echo "INFO: IMAGE_OFFER = $IMAGE_OFFER"

export IMAGE_VERSION=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.image.version}{"\n"}')
echo "INFO: IMAGE_VERSION = $IMAGE_VERSION"

export ARO_RESOURCE_GROUP=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.resourceGroup}{"\n"}')
echo "INFO: ARO_RESOURCE_GROUP = $ARO_RESOURCE_GROUP"

export VNET_NAME=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.vnet}{"\n"}')
echo "INFO: VNET_NAME = $VNET_NAME"

export SUBNET_NAME=$(oc get machineset/${CLUSTER_ID}-worker-${CLUSTER_LOCATION}1 -n openshift-machine-api -o jsonpath='{.spec.template.spec.providerSpec.value.subnet}{"\n"}')
echo "INFO: SUBNET_NAME = $SUBNET_NAME"



######
# Create the openshift storage namespace
if [[ -z $(oc get namespace | grep "openshift-storage") ]]; then
    echo "INFO: Creating namespace openshift-storage"
    cat << EOF | oc apply -f - 
apiVersion: v1
kind: Namespace
metadata:
  labels:
    openshift.io/cluster-monitoring: "true"
  name: "openshift-storage"
spec: {}
EOF
else
    echo "INFO: Using existing openshift-storage namespace"
fi

#####
# Create ODF operator group
if [[ -z $(oc get operatorgroup -n openshift-storage | grep openshift-storage-operatorgroup) ]]; then
    echo "INFO: Creating operator group openshift-storage-operatorgroup under namespace openshift-storage"
    cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
    name: openshift-storage-operatorgroup
    namespace: openshift-storage
spec:
    targetNamespaces:
    - openshift-storage
EOF
else
    echo "INFO: Using existing operator group"
fi

#####
# Create ODF subscription
if [[ -z $(oc get subscription -n openshift-storage | grep odf-operator) ]]; then
    echo "INFO: Creating subscription for odf-operator"
    cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
    name: odf-operator
    namespace: openshift-storage
spec:
    channel: "stable-${OCP_VERSION}"
    installPlanApproval: Automatic
    name: odf-operator
    source: redhat-operators
    sourceNamespace: openshift-marketplace
EOF
else
    echo "INFO: Using existing odf-operator subscription"
fi

wait_for_subscription openshift-storage odf-operator

####
# Patch the console to add the ODF console
if [[ -z $(oc get console.operator cluster -n openshift-storage -o json | grep odf-console) ]]; then
    echo "INFO: Patching openshift console to add ODF console"
    oc patch console.operator cluster -n openshift-storage --type json -p '[{"op": "add", "path": "/spec/plugins", "value": ["odf-console"]}]'
else
    echo "INFO: Openshift console already patched for ODF console"
fi

if [[ $EXISTING_NODES == "no" ]]; then
  echo "INFO: Creating new machinesets for ODF storage cluster"

  ####
  # Generate new machineset for ODF storage cluster - zone 1
  if [[ -z $(oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1) ]]; then
      echo "INFO: Creating machineset for zone 1 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ${IMAGE_OFFER}
            publisher: azureopenshift
            resourceID: ''
            sku: ${IMAGE_SKU}
            version: ${IMAGE_VERSION}
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${ARO_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "1" 
EOF
  else
      echo "INFO: Using existing machinesets for zone 1 for ODF storage cluster"
  fi

  ####
  # Generate new machineset for ODF storage cluster - zone 2
  if [[ -z $(oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2) ]]; then
      echo "INFO: Creating machineset for zone 2 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ${IMAGE_OFFER}
            publisher: azureopenshift
            resourceID: ''
            sku: ${IMAGE_SKU}
            version: ${IMAGE_VERSION}
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${ARO_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "2" 
EOF
  else
      echo "INFO: Using existing machinesets for zone 2 for ODF storage cluster"
  fi

  ####
  # Generate new machineset for ODF storage cluster - zone 3
  if [[ -z $(oc get machineset -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3) ]]; then
      echo "INFO: Creating machineset for zone 3 for ODF storage cluster"
      cat << EOF | oc apply -f -
apiVersion: machine.openshift.io/v1beta1
kind: MachineSet
metadata:
  labels:
    machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
    machine.openshift.io/cluster-api-machine-role: worker
    machine.openshift.io/cluster-api-machine-type: worker
  name: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
  namespace: openshift-machine-api
spec:
  replicas: 1
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
      machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
  template:
    metadata:
      creationTimestamp: null
      labels:
        machine.openshift.io/cluster-api-cluster: ${CLUSTER_ID} 
        machine.openshift.io/cluster-api-machine-role: worker
        machine.openshift.io/cluster-api-machine-type: worker
        machine.openshift.io/cluster-api-machineset: ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3
    spec:
      metadata:
        creationTimestamp: null
        labels:
          cluster.ocs.openshift.io/openshift-storage: ""
      providerSpec:
        value:
          apiVersion: azureproviderconfig.openshift.io/v1beta1
          credentialsSecret:
            name: azure-cloud-credentials
            namespace: openshift-machine-api
          image:
            offer: ${IMAGE_OFFER}
            publisher: azureopenshift
            resourceID: ''
            sku: ${IMAGE_SKU}
            version: ${IMAGE_VERSION}
          internalLoadBalancer: ""
          kind: AzureMachineProviderSpec
          location: ${CLUSTER_LOCATION}
          metadata:
            creationTimestamp: null
          natRule: null
          networkResourceGroup: ${RESOURCE_GROUP}
          osDisk:
            diskSizeGB: 128
            managedDisk:
              storageAccountType: Premium_LRS
            osType: Linux
          publicIP: false
          publicLoadBalancer: ${CLUSTER_ID}
          resourceGroup: ${ARO_RESOURCE_GROUP} 
          sshPrivateKey: ""
          sshPublicKey: ""
          subnet: ${SUBNET_NAME}  
          userDataSecret:
            name: worker-user-data 
          vmSize: Standard_D16s_v3
          vnet: ${VNET_NAME}
          zone: "3" 
EOF
  else
      echo "INFO: Using existing machinesets for zone 3 for ODF storage cluster"
  fi

  #####
  # Wait for machines to provision
  count=0
  while [[ $(oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}1 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]] \
      || [[ $(oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}2 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]] \
      || [[ $(oc get machinesets -n openshift-machine-api ${CLUSTER_ID}-odf-${CLUSTER_LOCATION}3 -o jsonpath='{.status.availableReplicas}{"\n"}') != "1" ]]; do
      echo "INFO: Waiting for machinesets to become available. Waiting $count minutes. Will wait up to 30 minutes."
      sleep 60
      count=$(( $count + 1 ))
      if (( $count > 30 )); then
          echo "ERROR: Timeout waiting for cluster operators to be available"
          exit 1;    
      fi
  done

else
  echo "INFO: Labelling existing worker nodes for use with ODF storage cluster"

  # Get list of worker nodes
  echo "INFO: Getting list of worker nodes"
  NODES=( $(oc get nodes | grep worker | awk '{print $1}') )

  # Confirm that there are 3 nodes available
  if (( $(echo ${#NODES[@]}) < 3  )); then
    echo "ERROR: Insufficient nodes for storage cluster. Must have at least 3 nodes available"
    exit 1
  fi

  # Get the size and zone of each node in array
  echo "INFO: Getting node details"
  for node in ${NODES[@]}; do
    cpu=$(oc get node $node -o json | jq -r '.status.capacity.cpu')
    mem=$(oc get node $node -o json | jq -r '.status.capacity.memory')
    zone=$(oc get machine -n openshift-machine-api | grep $node | awk '{print $5}')
    if (( $cpu > 15 )); then
      if [[ -z $(oc get node ${ODF_NODES_ZONE1[1]//\"/} -o json | jq '.metadata.labels' | grep "cluster.ocs.openshift.io") ]]; then
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
  done | jq -n '.nodes |= [inputs]' > ${WORKSPACE_DIR}/node-details.json

  NODE_DETAIL="$(cat ${WORKSPACE_DIR}/node-details.json)"

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
      oc label node ${ODF_NODES_ZONE1[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
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
      oc label node ${ODF_NODES_ZONE2[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
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
      oc label node ${ODF_NODES_ZONE3[0]//\"/} cluster.ocs.openshift.io/openshift-storage=''
    fi
  fi

fi


#####
# Create the storage cluster
if [[ -z $(oc get storagecluster -n openshift-storage ocs-storagecluster) ]]; then
    echo "INFO: Creating storage cluster ocs-storagecluster"
    cat << EOF | oc apply -f -
apiVersion: ocs.openshift.io/v1
kind: StorageCluster
metadata:
  name: ocs-storagecluster
  namespace: openshift-storage
spec:
  arbiter: {}
  encryption:
    kms: {}
  externalStorage: {}
  flexibleScaling: true
  resources:
    mds:
      limits:
        cpu: "3"
        memory: "8Gi"
      requests:
        cpu: "3"
        memory: "8Gi"
  monDataDirHostPath: /var/lib/rook
  managedResources:
    cephBlockPools:
      reconcileStrategy: manage   
    cephConfig: {}
    cephFilesystems: {}
    cephObjectStoreUsers: {}
    cephObjectStores: {}
  multiCloudGateway:
    reconcileStrategy: manage   
  storageDeviceSets:
  - count: 1  
    dataPVCTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: "${STORAGE_SIZE}"
        storageClassName: managed-premium
        volumeMode: Block
    name: ocs-deviceset
    placement: {}
    portable: false
    replica: 3
    resources:
      limits:
        cpu: "2"
        memory: "5Gi"
      requests:
        cpu: "2"
        memory: "5Gi"
EOF
else
    echo "INFO: Using existing storage cluster"
fi

######
# Wait for storage cluster to become available
count=0
while [[ $(oc get StorageCluster ocs-storagecluster -n openshift-storage --no-headers -o custom-columns='phase:status.phase') != "Ready" ]]; do
    echo "INFO: Waiting for storage cluster to become available. Waited $count minutes. Will wait up to 30 minutes"
    sleep 60
    count=$(( $count + 1 ))
    if (( $count > 30 )); then
        echo "ERROR: Timeout waiting for cluster operators to be available"
        exit 1;    
    fi
done
echo "ODF successfully installed on cluster $ARO_CLUSTER"