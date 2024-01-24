#!/bin/bash
# Creates a container in a loop for use to test deployment scripts

function usage() {
    echo "Creates a deployment script container ready for development and test use"
    echo 
    echo "Usage: ${0} -n NAMEPREFIX -g RESOURCEGROUP -v VNETNANE -s SUBNETNAME [-t DIR] [-h]"
    echo "  options"
    echo "  -n    prefix for the created resources. "
    echo "  -g    resource group in which to create resources"
    echo "  -v    VNet name containing subnet"
    echo "  -s    Subnet name to attach container to"
    echo "  -t    [optional] temporary directory path."
    echo "  -h    [optional] print this help and exit."
}

# Parse input arguments
while getopts ":n:t:h" option; do
    case $option in
        h)   # Display help
            usage
            exit 1;;
        n)  # Set the name prefix
            NAME_PREFIX=$OPTARG;;
        g)  # Set the resource group
            RESOURCE_GROUP=$OPT_ARG;;
        v)  # Set the VNet name
            VNET_NAME=$OPT_ARG;;
        s)  # Set the subnet name
            SUBNET_NAME=$OPT_ARG;;
        t)   # Set temp dir
            TMP_DIR=$OPTARG;;
        \?) 
            echo "ERROR: Invalid option"
            usage
            exit 1;;
    esac
done

if [[ -z $NAME_PREFIX ]]; then
    echo "ERROR: No name prefix specified"
    usage
    exit 1
fi

if [[ -z $RESOURCE_GROUP ]]; then
    echo "ERROR: No resource group specified"
    usage
    exit 1
fi

if [[ -z $VNET_NAME ]]; then
    echo "ERROR: No VNet name specified"
    usage
    exit 1
fi

if [[ -z $SUBNET_NAME ]]; then
    echo "ERROR: No Subnet name specified"
    usage
    exit 1
fi

# Set defaults if not specified (override with environment variables)
if [[ -z $TMP_DIR ]]; then TMP_DIR="/tmp"; fi
if [[ -z $TEMPLATE_FILENAME ]]; then TEMPLATE_FILENAME="deployment.json"; fi

# Create ARM template
cat << EOF > ${TMP_DIR}/$TEMPLATE_FILENAME
{
    "\$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
    "contentVersion": "1.0.0.0",
    "parameters": {
        "namePrefix": {
            "type": "string",
            "minLength": 3,
            "maxLength": 10,
            "metadata": {
                "description": "Prefix for resource names"
            }
        },
        "location": {
            "type": "string",
            "defaultValue": "[resourceGroup().location]",
            "metadata": {
                "description": "Location for deployment container"
            }
        },
        "vnetName": {
            "type": "string"
        },
        "subnetName": {
            "type": "string"
        },
        "rgRoleGuid": {
            "type": "string",
            "defaultValue": "[newGuid()]",
            "metadata": {
                "description": "forceUpdateTag property, used to force the execution of the script resource when no other properties have changed."
            }
        },
        "createStorageAccount": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Flag to determine whether to create a new storage account"
            }
        },
        "storageAccountName": {
            "type": "string",
            "defaultValue": "[concat(parameters('namePrefix'), 'deployscript')]",
            "metadata": {
                "description": "Name for the storage account for the script execution"
            }            
        },
        "createManagedIdentity": {
            "type": "bool",
            "defaultValue": true,
            "metadata": {
                "description": "Flag to determine whether to create a new managed identity for script execution"
            }
        },
        "managedIdName": {
            "type": "string",
            "defaultValue": "[concat(parameters('namePrefix'),'-script-sp')]",
            "metadata": {
                "description": "Name of the managed identity used for deployment scripts"
            }
        },
        "azureCliVersion": {
            "type": "string",
            "defaultValue": "2.45.0",
            "metadata": {
                "description": "Container image version to pull. Refer https://mcr.microsoft.com/v2/azure-cli/tags/list for list of available versions."
            }
        }
        
    },
    "variables": {
      "containerGroupName": "[concat(parameters('namePrefix'), '-cg')]",
      "scriptName": "[concat(parameters('namePrefix'),'-script')]",
      "roleDefinitionId": "[resourceId('Microsoft.Authorization/roleDefinitions', 'b24988ac-6180-42a0-ab88-20f7382dd24c')]",
      "roleDefinitionName": "[guid(resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', parameters('managedIdName')), variables('roleDefinitionId'), resourceGroup().id)]"
    },
    "resources": [
        {
            "type": "Microsoft.Resources/deploymentScripts",
            "apiVersion": "2020-10-01",
            "comments": "Deploys developer container",
            "name": "[variables('scriptName')]",
            "location": "[parameters('location')]",
            "identity": {
                "type": "UserAssigned",
                "userAssignedIdentities": {
                    "[resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', parameters('managedIdName'))]": {}
                }
            },
            "kind": "AzureCLI",
            "properties": {
                "forceUpdateTag": "[parameters('rgRoleGuid')]",
                "containerSettings": {
                    "containerGroupName": "[variables('containerGroupName')]",
                    "subnetIds": [
                        {
                            "id": "[resourceId('Microsoft.Network/virtualNetworks/subnets',parameters('vnetName'),parameters('subnetName'))]"
                        }
                    ]
                },
                "storageAccountSettings": {
                    "storageAccountName": "[parameters('storageAccountName')]",
                    "storageAccountKey": "[listKeys(resourceId('Microsoft.Storage/storageAccounts', parameters('storageAccountName')), '2022-09-01').keys[0].value]"
                },
                "azCliVersion": "[parameters('azureCliVersion')]",  
                "environmentVariables": [
                    {
                        "name": "RESOURCE_GROUP",
                        "value": "[resourceGroup().name]"
                    }
                ],
                "scriptContent": "while true; do sleep 30; done;",
                "timeout": "PT120M",
                "cleanupPreference": "OnSuccess",
                "retentionInterval": "P1D"
            },
            "dependsOn": [
                "[variables('roleDefinitionName')]"
            ]
        },
        {
            "type": "Microsoft.Storage/storageAccounts",
            "apiVersion": "2023-01-01",
            "condition": "[parameters('createStorageAccount')]",
            "name": "[parameters('storageAccountName')]",
            "location": "[parameters('location')]",
            "sku": {
                "name": "Standard_LRS",
                "tier": "Standard"
            },
            "kind": "StorageV2",
            "properties": {
                "accessTier": "Hot"
            }
        },
        {
            "type": "Microsoft.ManagedIdentity/userAssignedIdentities",
            "apiVersion": "2018-11-30",
            "name": "[parameters('managedIdName')]",
            "condition": "[parameters('createManagedIdentity')]",
            "location": "[parameters('location')]"
        },
        {
            "type": "Microsoft.Authorization/roleAssignments",
            "apiVersion": "2022-04-01",
            "name": "[variables('roleDefinitionName')]",
            "condition": "[parameters('createManagedIdentity')]",
            "dependsOn": [
                "[parameters('managedIdName')]"
            ],
            "properties": {
                "roleDefinitionId": "[variables('roleDefinitionId')]",
                "principalId": "[reference(parameters('managedIdName'), '2018-11-30').principalId]",
                "scope": "[resourceGroup().id]",
                "principalType": "ServicePrincipal"
            }
        }
    ]
}
EOF

# Check the resource group exists
if [[ -z $(az group list -o table | grep $RESOURCE_GROUP) ]]; then
    echo "ERROR: Resource group $RESOURCE_GROUP not found"
    exit 1
fi

# Check the VNet exists
if [[ -z $(az network vnet list -g $RESOURCE_GROUP -o table | grep $VNET_NAME) ]]; then
    echo "ERROR: Virtual network $VNET_NAME not found in resource group $RESOURCE_GROUP"
    exit 1
fi

# Check subnet exists
if [[ -z $(az network vnet subnet list -g $RESOURCE_GROUP --vnet-name $VNET_NAME -o table | grep $SUBNET_NAME) ]]; then
    echo "ERROR: Subnet $SUBNET_NAME not found in VNET, $VNET_NAME, in resource group $RESOURCE_GROUP"
    exit 1
fi

az deployment group create \
    --name "${NAME_PREFIX}-deploy-script"
    --resource-group $RESOURCE_GROUP \
    --template-file ${TMP_DIR}/${TEMPLATE_FILENAME} \
    --parameters namePrefix=${NAME_PREFIX} \
    --parameters vnetName=${VNET_NAME} \
    --parameters subnetName=${SUBNET_NAME}
