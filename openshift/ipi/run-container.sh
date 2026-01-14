#!/bin/bash
# 
# This script runs a container (pulls image if not present on workstation) 
# and mounts the local directory as the workspace.
#

IMAGE=${1}

# Defaults
if [[ -z $WORKSPACE_DIR ]]; then WORKSPACE_DIR="/workspace"; fi
if [[ -z $CONTAINER_NAME ]]; then CONTAINER_NAME="ocp-install"; fi
if [[ -z $MOUNT_DIR ]]; then MOUNT_DIR="$(pwd)"; fi

# Check container runtime to use
if [[ $(which podman 2> /dev/null) ]]; then
    RUNTIME="podman"
    echo "Container runtime set to podman"
elif [[ $(which docker 2> /dev/null ) ]]; then
    RUNTIME="docker"
    echo "Container runtime set to docker"
else
    echo "Neither podman nor docker found in path"
    exit 1
fi

ENV_FILE=""
if [[ -f "credentials.properties" ]]; then
  ENV_FILE="--env-file credentials.properties"
fi

# Clean up any old containers of the same name
echo "INFO: Cleaning up any old containers"
${RUNTIME} kill ${CONTAINER_NAME} 1> /dev/null 2> /dev/null
${RUNTIME} rm ${CONTAINER_NAME} 1> /dev/null 2> /dev/null

# Pull the image
echo "Pulling image ${IMAGE}"
${RUNTIME} pull ${IMAGE}

# Run container
echo "Running and attaching to container ${CONTAINER_NAME}"
${RUNTIME} run -it \
    --security-opt label=disable \
    -v ${MOUNT_DIR}:${WORKSPACE_DIR}:rw \
    ${ENV_FILE} \
    -w ${WORKSPACE_DIR} \
    ${IMAGE} 
