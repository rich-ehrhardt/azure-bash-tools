#/bin/bash

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
if [[ ! $(${BIN_DIR}/oc get namespace openshift-nfd 2> /dev/null) ]]; then
    echo "Creating namespace for Red Hat Node Feature Discovery Tool"
    cat << EOF | ${BIN_DIR}/oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
spec: {}
EOF
    if [[ $? != 0 ]]; then
        echo "ERROR: Unable to create new namespace"
        exit 1
    fi
else
    echo "OpenShift NFD namespace already exists"
fi

#####
# Create operator group
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: openshift-nfd-
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
  - openshift-nfd
  upgradeStrategy: Default
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create operator group"
    exit 1
fi

#####
# Create subscription
cat <<EOF | ${BIN_DIR}/oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: "stable"
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create subscription"
    exit 1
fi

######
# Wait for subscription to bind to CSV
wait_for_subscription openshift-nfd nfd

######
# Create the operand
cat << EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: 'registry.redhat.io/openshift4/ose-node-feature-discovery@sha256:d3cbb53bce95ed48293d41c67d6031c244b592070a8f16e0d5a75f1fd6cf6055'
    servicePort: 12000
  workerConfig:
    configData: |
      core:
      #  labelWhiteList:
      #  noPublish: false
        sleepInterval: 60s
      #  sources: [all]
      #  klog:
      #    addDirHeader: false
      #    alsologtostderr: false
      #    logBacktraceAt:
      #    logtostderr: true
      #    skipHeaders: false
      #    stderrthreshold: 2
      #    v: 0
      #    vmodule:
      ##   NOTE: the following options are not dynamically run-time 
      ##          configurable and require a nfd-worker restart to take effect
      ##          after being changed
      #    logDir:
      #    logFile:
      #    logFileMaxSize: 1800
      #    skipLogHeaders: false
      sources:
      #  cpu:
      #    cpuid:
      ##     NOTE: whitelist has priority over blacklist
      #      attributeBlacklist:
      #        - "BMI1"
      #        - "BMI2"
      #        - "CLMUL"
      #        - "CMOV"
      #        - "CX16"
      #        - "ERMS"
      #        - "F16C"
      #        - "HTT"
      #        - "LZCNT"
      #        - "MMX"
      #        - "MMXEXT"
      #        - "NX"
      #        - "POPCNT"
      #        - "RDRAND"
      #        - "RDSEED"
      #        - "RDTSCP"
      #        - "SGX"
      #        - "SSE"
      #        - "SSE2"
      #        - "SSE3"
      #        - "SSE4.1"
      #        - "SSE4.2"
      #        - "SSSE3"
      #      attributeWhitelist:
      #  kernel:
      #    kconfigFile: "/path/to/kconfig"
      #    configOpts:
      #      - "NO_HZ"
      #      - "X86"
      #      - "DMI"
        pci:
          deviceClassWhitelist:
            - "0200"
            - "03"
            - "12"
          deviceLabelFields:
      #      - "class"
            - "vendor"
      #      - "device"
      #      - "subsystem_vendor"
      #      - "subsystem_device"
      #  usb:
      #    deviceClassWhitelist:
      #      - "0e"
      #      - "ef"
      #      - "fe"
      #      - "ff"
      #    deviceLabelFields:
      #      - "class"
      #      - "vendor"
      #      - "device"
      #  custom:
      #    - name: "my.kernel.feature"
      #      matchOn:
      #        - loadedKMod: ["example_kmod1", "example_kmod2"]
      #    - name: "my.pci.feature"
      #      matchOn:
      #        - pciId:
      #            class: ["0200"]
      #            vendor: ["15b3"]
      #            device: ["1014", "1017"]
      #        - pciId :
      #            vendor: ["8086"]
      #            device: ["1000", "1100"]
      #    - name: "my.usb.feature"
      #      matchOn:
      #        - usbId:
      #          class: ["ff"]
      #          vendor: ["03e7"]
      #          device: ["2485"]
      #        - usbId:
      #          class: ["fe"]
      #          vendor: ["1a6e"]
      #          device: ["089a"]
      #    - name: "my.combined.feature"
      #      matchOn:
      #        - pciId:
      #            vendor: ["15b3"]
      #            device: ["1014", "1017"]
      #          loadedKMod : ["vendor_kmod1", "vendor_kmod2"]
  customConfig:
    configData: |
      #    - name: "more.kernel.features"
      #      matchOn:
      #      - loadedKMod: ["example_kmod3"]
      #    - name: "more.features.by.nodename"
      #      value: customValue
      #      matchOn:
      #      - nodename: ["special-.*-node-.*"]
EOF

if [[ $? != 0 ]]; then
    echo "ERROR: Unable to create node feature discovery operand"
    exit 1
fi

######
# Wait for NFD operand to be ready
count=0;
while [[ $(${BIN_DIR}/oc get nodefeaturediscovery -n openshift-nfd nfd-instance -o jsonpath='{.status.conditions[?(.type=="Available")].status}') != "True" ]]; do
    echo "INFO: Waiting for Node Feature Discovery to be ready. Waited $(( $count * 30 )) seconds. Will wait up to $(( $TIMEOUT_COUNT * 30 )) seconds."
    sleep 30
    count=$(( $count + 1 ))
    if (( $count > $TIMEOUT_COUNT )); then
        echo "ERROR: Timeout exceeded waiting for DSC Initialization to be ready"
        exit 1
    fi
done


