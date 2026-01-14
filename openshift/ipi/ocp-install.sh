#!/bin/bash

function log-output() {
    MSG=${1}

    if [[ -z $OUTPUT_DIR ]]; then
        OUTPUT_DIR="/mnt/azscripts/azscriptoutput"
    fi
    mkdir -p $OUTPUT_DIR

    if [[ -z $OUTPUT_FILE ]]; then
        OUTPUT_FILE="script-output.log"
    fi

    echo "$(date -u +"%Y-%m-%d %T") ${MSG}" >> ${OUTPUT_DIR}/${OUTPUT_FILE}
    echo ${MSG}
}

function log-info() {
    MSG=${1}

    log-output "INFO: $MSG"    
}

function log-error() {
    MSG=${1}

    log-output "ERROR: $MSG"
    echo $MSG >&2
}

function oc-login() {
# Login to an OpenShift cluster. 
# Usage:
#        oc-login API_SERVER OCP_USERNAME OCP_PASSWORD BIN_DIR 
#

    if [[ -z ${1} ]] || [[ -z $API_SERVER ]]; then
        log-error "API_SERVER not passed to function oc-login"
        exit 1
    elif [[ ${1} != "" ]]; then
        API_SERVER=${1}
    fi

    if [[ -z ${2} ]] || [[ -z $OCP_USERNAME ]]; then
        log-error "OCP_USERNAME not passed to function oc-login"
        exit 1
    elif [[ ${2} != "" ]]; then
        OCP_USERNAME=${2}
    fi

    if [[ -z ${3} ]] || [[ -z $OCP_PASSWORD ]]; then
        log-error "OCP_PASSWORD not passed to function oc-login"
        exit 1
    elif [[ ${3} != "" ]]; then
        OCP_PASSWORD=${3}
    fi

    if [[ -z ${4} ]] || [[ -z $BIN_DIR ]]; then
        BIN_DIR="/usr/local/bin"
    elif [[ ${4} != "" ]]; then
        BIN_DIR="${4}"
    fi

    if ! ${BIN_DIR}/oc status 1> /dev/null 2> /dev/null; then
        log-info "Logging into OpenShift cluster $API_SERVER"

        # Below loop added to allow authentication service to start on new clusters
        count=0
        while ! ${BIN_DIR}/oc login $API_SERVER -u $OCP_USERNAME -p $OCP_PASSWORD --insecure-skip-tls-verify=true 1> /dev/null 2> /dev/null ; do
            log-info "Waiting to log into cluster. Waited $count minutes. Will wait up to 15 minutes."
            sleep 60
            count=$(( $count + 1 ))
            if (( $count > 15 )); then
                log-error "Timeout waiting to log into cluster"
                exit 1;    
            fi
        done
        log-info "Successfully logged into cluster $API_SERVER"
    else   
        CURRENT_SERVER=$(${BIN_DIR}/oc status | grep server | awk '{printf $6}' | sed -e 's#^https://##; s#/##')

        if [[ $CURRENT_SERVER == $API_SERVER ]]; then
            log-info "Already logged into cluster"
        else

            # Below loop added to allow authentication service to start on new clusters
            count=0
            while ! ${BIN_DIR}/oc login $API_SERVER -u $OCP_USERNAME -p $OCP_PASSWORD --insecure-skip-tls-verify=true > /dev/null 2>&1 ; do
                log-info "Waiting to log into cluster. Waited $count minutes. Will wait up to 15 minutes."
                sleep 60
                count=$(( $count + 1 ))
                if (( $count > 15 )); then
                    log-error "Timeout waiting to log into cluster"
                    exit 1;    
                fi
            done
            log-info "Successfully logged into cluster $API_SERVER"
        fi
    fi
}

function cli-download() {
    
    if [[ -z ${1} ]]; then
        local BIN_DIR="/usr/local/bin"
    else
        local BIN_DIR=${1}
    fi

    if [[ -z ${2} ]]; then
        local TMP_DIR="/tmp"
    else
        local TMP_DIR=${2}
    fi

    if [[ -z ${3} ]] || [[ ${3}  == "4" ]] || [[ ${3} == "stable" ]]; then
        # Install the latest stable version
        local OC_VERSION="stable"
        local OCP_RELEASE=14
    elif [[ ${VERSION} =~ [0-9][.][0-9]+[.][0-9]+ ]]; then
        # Install a specific version and patch level
        local OC_VERSION="${VERSION}"
        local OCP_RELEASE=$(( $(echo $VERSION | awk -F'.' '{print $2}') ))
    else
        # Install the latest stable subversion
        local OC_VERSION="stable-${3}"
        local OCP_RELEASE=$(( $(echo ${3} | awk -F'.' '{print $2}') ))
    fi

    local ARCH=$(uname -m)
    local OC_FILETYPE="linux"
    local OC_URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OC_VERSION}/openshift-client-${OC_FILETYPE}.tar.gz"

    if [[ -f ${BIN_DIR}/oc ]]; then
        log-info "Openshift client binary already installed"
    else
        log-info "Downloading and installing oc"
        curl -sLo $TMP_DIR/openshift-client.tgz $OC_URL

        if ! error=$(tar xzf ${TMP_DIR}/openshift-client.tgz -C ${TMP_DIR} oc 2>&1) ; then
            log-error "Unable to extract oc from tar file"
            log-error "$error"
            exit 1
        fi

        if ! error=$(mv ${TMP_DIR}/oc ${BIN_DIR}/oc 2>&1) ; then
            log-error "Unable to move oc to $BIN_DIR"
            log-error "$error"
            exit 1
        fi
    fi

}

function cleanup_file() {
    FILE=${1}

    if [[ -f $FILE ]]; then
        rm $FILE
    fi
}

function download-openshift-installer() {
    local DEST_DIR=${1}
    local VERSION=${2}
    local BIN_DIR=${3}

    local ARCH=$(uname -m)
    local FILETYPE="linux"

    if [[ -z $VERSION ]] || [[ ${VERSION}  == "4" ]]; then
        # Install the latest stable version
        local OCP_VERSION="stable"
        local OCP_RELEASE=14
    elif [[ ${VERSION} =~ [0-9][.][0-9]+[.][0-9]+ ]]; then
        # Install a specific version and patch level
        local OCP_VERSION="${VERSION}"
        local OCP_RELEASE=$(( $(echo $VERSION | awk -F'.' '{print $2}') ))
    else
        # Install the latest stable subversion
        local OCP_VERSION="stable-${VERSION}"
        local OCP_RELEASE=$(( $(echo $VERSION | awk -F'.' '{print $2}') ))
    fi

    URL="https://mirror.openshift.com/pub/openshift-v4/${ARCH}/clients/ocp/${OCP_VERSION}/openshift-install-${FILETYPE}.tar.gz"

    if [[ -z ${BIN_DIR} ]]; then
        local BIN_DIR="$(pwd)"
        log-info "Setting openshift-install binary installation directory to $BIN_DIR"
    else
        log-info "Openshift-install binary installation directory is set to $BIN_DIR"
    fi

    if [[ -f ${BIN_DIR}/openshift-install ]]; then
        log-info "Openshift install binary already installed"
    else
        if [[ -z ${DEST_DIR} ]]; then
            local DEST_DIR="$(pwd)"
            log-info "Setting openshift-install download directory to $DEST_DIR"
        else
            log-info "Openshift-install download directory is set to $DEST_DIR"
        fi

        log-info "Downloading OpenShift installer CLI version $OCP_VERSION"
        curl -sLo ${DEST_DIR}/openshift-install-${FILETYPE}.tar.gz $URL
        if (( $? != 0 )); then
            log-error "Unable to download openshift installer from $URL"
            exit 1
        fi

        log-info "Extracting openshift-install"
        if ! error=$(tar xzf ${DEST_DIR}/openshift-install-${FILETYPE}.tar.gz -C ${DEST_DIR} openshift-install 2>&1) ; then
            log-error "Unable to extract openshift-install from tar file"
            log-error "$error"
            exit 1
        fi

        log-info "Moving openshift-install to $BIN_DIR"
        if ! error=$(mv ${DEST_DIR}/openshift-install ${BIN_DIR}/openshift-install 2>&1) ; then
            log-error "Unable to move openshift-install to $BIN_DIR"
            log-error "$error"
            exit 1
        fi

    fi

}

function wait_for_cluster_operators() {
# Usage:
#        wait_for_cluster_operators API_SERVER OCP_USERNAME OCP_PASSWORD BIN_DIR 
#

    if [[ -z ${1} ]] || [[ -z $API_SERVER ]]; then
        log-error "API_SERVER not passed to function oc-login"
        exit 1
    elif [[ ${1} != "" ]]; then
        API_SERVER=${1}
    fi

    if [[ -z ${2} ]] || [[ -z $OCP_USERNAME ]]; then
        log-error "OCP_USERNAME not passed to function oc-login"
        exit 1
    elif [[ ${2} != "" ]]; then
        OCP_USERNAME=${2}
    fi

    if [[ -z ${3} ]] || [[ -z $OCP_PASSWORD ]]; then
        log-error "OCP_PASSWORD not passed to function oc-login"
        exit 1
    elif [[ ${3} != "" ]]; then
        OCP_PASSWORD=${3}
    fi

    if [[ -z ${4} ]] || [[ -z $BIN_DIR ]]; then
        BIN_DIR="/usr/local/bin"
    elif [[ ${4} != "" ]]; then
        BIN_DIR="${4}"
    fi

    log-info "Checking for cluster operator status"
    # Attempt to login to cluster if not already
    if ! ${BIN_DIR}/oc status 1> /dev/null 2> /dev/null; then
        log-info "Attempting login to OpenShift cluster $API_SERVER"

        # Below loop added to allow authentication service to start on new clusters
        count=0
        while ! ${BIN_DIR}/oc login $API_SERVER -u $OCP_USERNAME -p $OCP_PASSWORD --insecure-skip-tls-verify=true 1> /dev/null 2> /dev/null ; do
            log-info "Waiting to log into cluster. Waited $count minutes. Will wait up to 15 minutes."
            sleep 60
            count=$(( $count + 1 ))
            if (( $count > 15 )); then
                log-error "Timeout waiting to log into cluster"
                exit 1;    
            fi
        done
        log-info "Successfully logged into cluster $API_SERVER"
        existing_login="no"
    else
        log-info "Already logged into cluster"
        existing_login="yes"
    fi

    # Wait for cluster operators to be available
    count=0
    while ${BIN_DIR}/oc get clusteroperators | awk '{print $4}' | grep True; do
        log-info "Waiting on cluster operators to be availabe. Waited $count minutes. Will wait up to 30 minutes."
        sleep 60
        count=$(( $count + 1 ))
        if (( $count > 30 )); then
            log-error "Timeout waiting for cluster operators to be available"
            exit 1;
        fi
    done
    log-info "Cluster operators are ready"

    # Log out of cluster to allow secure login
    # Not needed for unmanaged
    # if [[ $existing_login == "no" ]]; then
    #     log-info "Logging out of temporary cluster login"
    #     oc logout 1> /dev/null 2> /dev/null
    # fi
}

### Parse arguments
OCP_VERSION="${1}"

### Set defaults
if [[ -z ${WORKSPACE_DIR} ]]; then WORKSPACE_DIR="/workspace"; fi
if [[ -z ${BIN_DIR} ]]; then BIN_DIR="/usr/local/bin"; fi
if [[ -z ${OUTPUT_DIR} ]]; then OUTPUT_DIR="/tmp"; fi

### Download openshift installer binary
download-openshift-installer ${WORKSPACE_DIR} ${OCP_VERSION} ${BIN_DIR}

### Configure credentials
mkdir -p ~/.azure/
echo {"subscriptionId":"${SUBSCRIPTION_ID}","clientId":"${CLIENT_ID}","clientSecret":"${CLIENT_SECRET}","tenantId":"${TENANT_ID}"} > ~/.azure/osServicePrincipal.json

### Confirm cluster operators

### Download oc client
cli-download ${BIN_DIR} ${WORKSPACE_DIR} ${OCP_VERSION}
