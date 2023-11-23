#!/bin/bash

function usage() {
    echo "Usage is:"
    echo "$0 filename"
    echo "where"
    echo "filename = path and name of file containing list of ids to delete"
    return 0
}

if [[ -z $1 ]]; then
    usage
    exit 1
fi

while read id; do
    echo "Deleting sp id $id"
    az ad sp delete --id $id
done <$1