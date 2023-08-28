#!/bin/bash

function menu() {
    local item i=1 numItems=$#

    for item in "$@"; do
        printf '%s %s\n' "$((i++))" "$item"
    done >&2

    while :; do
        printf %s "${PS3-#? }" >&2
        read -r input
        if [[ -z $input ]]; then
            break
        elif (( input < 1 )) || (( input > numItems )); then
          echo "Invalid Selection. Enter number next to item." >&2
          continue
        fi
        break
    done

    if [[ -n $input ]]; then
        printf %s "${@: input:1}"
    fi
}

function get-resource-group() {
    
    existing_rg=""
    while [[ $existing_rg == "" ]]; do
        echo -n "Existing resource group? [Y] : "
        read input
        input=$(echo ${input:0:1} | tr '[:upper:]' '[:lower:]' )
        case $input in
            '') existing_rg="yes";;
            'y') existing_rg="yes";;
            'n') existing_rg="no";;
            *) echo "Unknown input";;
        esac
    done

    if [[ $existing_rg == "yes" ]]; then
        IFS=$'\n'
        read -r -d '' -a RGS < <(az group list --query '[].name' -o tsv)
        PS3="Select the resource group : "
        RG=$(menu "${RGS[@]}")
    else
        echo -n "Enter the name of the resource group to create : "
        read RG
    fi

    echo $RG
}

function get-location() {

    IFS=$'\n'

    # Get list of available locations
    LOCATION_LIST=$(az account list-locations --query '[].{Area:metadata.geographyGroup, Name:name}')

    # Get list of geographies
    read -r -d '' -a AREAS < <(echo $LOCATION_LIST | jq -r '.[].Area' | uniq | sort -u | grep -v null)
    DEFAULT_AREA="US"
    PS3="Select the deployment geography [$DEFAULT_AREA]: "
    area=$(menu "${AREAS[@]}")
    case $area in
        '') AREA="$DEFAULT_AREA"; ;;
        *) AREA=$area; ;;
    esac

    echo
    read -r -d '' -a REGIONS < <(echo $LOCATION_LIST | jq -r ".[] | select(.Area==\"$AREA\") | .Name" | uniq | sort -u)
    if [[ $AREA == "US" ]]; then
        DEFAULT_REGION="eastus"
    else
        DEFAULT_REGION=""
    fi

    PS3="Select the region [$DEFAULT_REGION]: "
    region=$(menu "${REGIONS[@]}")
    case $region in
        '') REGION="$DEFAULT_REGION"; ;;
        *) REGION="$region"; ;;
    esac

    echo $REGION
}