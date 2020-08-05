#!/bin/bash
set -e

#Set defaults
default_tag=latest
default_location=westeurope
default_rg=azure-toolbox
default_plan=grafana-linux-plan
default_sku=B1

#Set script variables
webapp=$1
tag=$2
location=$3
rg=$4
plan=$5
sku=$6

function show_usage_and_exit {
  echo "Usage: setup-grafana.azcli <webapp> [<tag>] [<location>] [<resource-group>] [<app-service-plan>] [<sku>]"
  echo "<webapp> specifies the Web App name, i.e. <webapp>.azurewebsites.net. Mandatory."
  echo "<tag> specifies the Grafana Docker image tag. Defaults to \"$default_tag\"."
  echo "<location> specifies the Azure region. Defaults to \"$default_location\"."
  echo "<resource-group> specifies the resource group. Defaults to \"$default_rg\"."
  echo "<app-service-plan> specifies the App Service plan. Defaults to \"$default_plan\"."
  echo "<sku> specifies the App Service SKU. Defaults to \"$default_sku\"."
  exit 1
}

if [ -z $webapp ]; then
  show_usage_and_exit
fi

if [ -z $tag ]; then
  tag=$default_tag
fi

if [ -z $location ]; then
  location=$default_location
fi

if [ -z $rg ]; then
  rg=$default_rg
fi

if [ -z $plan ]; then
  plan=$default_plan
fi

if [ -z $sku ]; then
  sku=$default_sku
fi

# Register Azure AD application and service principal
aad_tenant_id=$(az account show --query tenantId -o tsv)
echo "Registering application for Grafana in Azure AD in tenant \"$aad_tenant_id\"..."
time_stamp=$(date --utc +"%s")
aad_app_secret=$(uuidgen)
aad_app_id=$(az ad app create \
  --display-name "Grafana Azure App Service" \
  --identifier-uris "http://$webapp-$time_stamp" \
  --password $aad_app_secret \
  --homepage "https://$webapp.azurewebsites.net" \
  --reply-urls "http://localhost:3000/login/azuread" "https://$webapp.azurewebsites.net/login/azuread" \
  --app-roles @manifest.json \
  --query appId \
  -o tsv)
resource_id=$(az ad sp create \
  --id $aad_app_id \
  --query objectId \
  -o tsv)

echo "Waiting for service principal..."
sleep 45
principal_id=$(az ad signed-in-user show --query objectId -o tsv)
user_name=$(az account show --query user.name -o tsv)

# Azure CLI doesn not offer a command to assign app roles directly, so we use the Graph API
echo "Assigning Grafana Admin role to $user_name with principal id $principal_id..."
cp appRoleAssignment.azuread.json appRoleAssignment.generated.json
sed -i "s/__1__/$principal_id/g" appRoleAssignment.generated.json
sed -i "s/__2__/$resource_id/g" appRoleAssignment.generated.json
az rest \
  --method post \
  --uri https://graph.microsoft.com/v1.0/users/$principal_id/appRoleAssignments \
  --body @appRoleAssignment.generated.json \
  --headers "Content-Type=application/json" \
  -o none

# Create configuration settings
admin_pwd=$(uuidgen)

echo "Generating Docker Compose file..."
cp docker-compose.azuread.yml docker-compose.generated.yml
sed -i "s/__1__/$tag/g" docker-compose.generated.yml
sed -i "s/__2__/$aad_app_id/g" docker-compose.generated.yml
sed -i "s/__3__/$aad_app_secret/g" docker-compose.generated.yml
sed -i "s/__4__/$aad_tenant_id/g" docker-compose.generated.yml
sed -i "s/__5__/$admin_pwd/g" docker-compose.generated.yml

echo "Generating Web App configuration..."
cp appSettings.azuread.json appSettings.generated.json
sed -i "s/__1__/$webapp/g" appSettings.generated.json
sed -i "s/__2__/$aad_app_id/g" appSettings.generated.json
sed -i "s/__3__/$aad_app_secret/g" appSettings.generated.json
sed -i "s/__4__/$aad_tenant_id/g" appSettings.generated.json
sed -i "s/__5__/$admin_pwd/g" appSettings.generated.json

# Create Azure resources
echo "Creating resource group \"$rg\" in \"$location\"..."
az group create \
  -g $rg \
  -l $location \
  -o none

echo "Creating App Service plan \"$plan\" of size \"$sku\"..."
az appservice plan create \
  -g $rg \
  -n $plan \
  -l $location \
  --is-linux \
  --sku $sku \
  -o none

echo "Creating Web App \"$webapp\" using \"grafana/grafana:$tag\"..."
az webapp create \
  -g $rg \
  -n $webapp \
  -p $plan \
  -i grafana/grafana:$tag \
  -o none
az webapp update \
  -g $rg \
  -n $webapp \
 --https-only true \
 -o none

echo "Updating Web App configuration..."
az webapp config appsettings set \
  -g $rg \
  -n $webapp \
  --settings @appSettings.generated.json \
  -o none
az webapp config set \
  -g $rg \
  -n $webapp \
  --always-on true \
  -o none

echo "Done. Open https://$webapp.azurewebsites.net or run \"docker-compose -f docker-compose.generated.yml\"."
