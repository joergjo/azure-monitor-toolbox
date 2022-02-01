#!/bin/bash
set -e

#Set defaults
default_tag=latest
default_location=westeurope
default_rg=grafana-on-azure
default_plan=grafana-linux-plan
default_appsvc_sku=B1
default_postgresql_sku=B_Gen5_1
default_postgresql_storage=51200

#Set script variables
webapp=$1
tag=$2
location=$3
rg=$4
plan=$5
appsvc_sku=$6
postgresql_sku=$7
postgresql_storage=$8

function show_usage_and_exit {
  echo "This script creates an Azure App Service running Grafana with an Azure Database for PostgreSQL as Grafana database."
  echo "Grafana will be integrated with your current Azure AD tenant and your current Azure CLI user will be added"
  echo "to the \"Grafana Admin\" Azure AD application role."
  echo
  echo "Usage: setup.sh <webapp> [<tag>] [<location>] [<resource-group>] [<app-service-plan>] [<app-service-sku>] [<postgresql-sku>] [<postgresql-storage>]"
  echo "<webapp> specifies the Web App name, i.e. <webapp>.azurewebsites.net. Mandatory."
  echo "<tag> specifies the Grafana Docker image tag. Defaults to \"$default_tag\"."
  echo "<location> specifies the Azure region. Defaults to \"$default_location\"."
  echo "<resource-group> specifies the resource group. Defaults to \"$default_rg\"."
  echo "<app-service-plan> specifies the App Service plan. Defaults to \"$default_plan\"."
  echo "<app-service-sku> specifies the App Service SKU. Defaults to \"$default_appsvc_sku\"."
  echo "<postgresql-sku> specifies the Azure Database for PostgreSQL SKU. Defaults to \"$default_postgresql_sku\"."
  echo "<postgresql-storage> specifies the Azure Database for PostgreSQL storage in MB. Defaults to \"$default_postgresql_storage\" MB."
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

if [ -z $appsvc_sku ]; then
  appsvc_sku=$default_appsvc_sku
fi

if [ -z $postgresql_sku ]; then
  postgresql_sku=$default_postgresql_sku
fi

if [ -z $postgresql_storage ]; then
  postgresql_storage=$default_postgresql_storage
fi

# Register Azure AD application and service principal
aad_tenant_id=$(az account show --query tenantId -o tsv)
echo -n "Registering application for Grafana in Azure AD in tenant \"$aad_tenant_id\"..."
time_stamp=$(date --utc +%Y%m%d-%H%M%S)
aad_app_secret=$(uuidgen)
aad_app_id=$(az ad app create \
  --display-name "Grafana Azure App Service" \
  --password $aad_app_secret \
  --homepage "https://$webapp.azurewebsites.net" \
  --reply-urls "http://localhost:3000/login/azuread" "https://$webapp.azurewebsites.net/login/azuread" \
  --app-roles @manifest.json \
  --query appId \
  -o tsv)
echo "done."
echo "Created application with client ID \"$aad_app_id\"."

resource_id=$(az ad sp create \
  --id $aad_app_id \
  --query objectId \
  -o tsv)

echo -n "Waiting for service principal \"$resource_id\"..."
sleep 45
echo "done."

# Azure CLI doesn not offer a command to assign app roles directly, so we use the Graph API
principal_id=$(az ad signed-in-user show --query objectId -o tsv)
current_user=$(az account show --query user.name -o tsv)
echo -n "Assigning Grafana Admin role to \"$current_user\" with principal id \"$principal_id\"..."
cp appRoleAssignment.azuread.json appRoleAssignment.generated.json
sed -i "s/__1__/$principal_id/g" appRoleAssignment.generated.json
sed -i "s/__2__/$resource_id/g" appRoleAssignment.generated.json
az rest \
  --method post \
  --uri https://graph.microsoft.com/v1.0/users/$principal_id/appRoleAssignments \
  --body @appRoleAssignment.generated.json \
  --headers "Content-Type=application/json" \
  -o none
echo "done."

# Create configuration settings
admin_pwd=$(uuidgen)
db_host=$webapp-db
db_user=grafana
db_pwd=$(uuidgen)

echo -n "Generating Docker Compose file..."
cp docker-compose.azuread.yml docker-compose.generated.yml
sed -i "s/__1__/$tag/g" docker-compose.generated.yml
sed -i "s/__2__/$aad_app_id/g" docker-compose.generated.yml
sed -i "s/__3__/$aad_app_secret/g" docker-compose.generated.yml
sed -i "s/__4__/$aad_tenant_id/g" docker-compose.generated.yml
sed -i "s/__5__/$admin_pwd/g" docker-compose.generated.yml
sed -i "s/__6__/$db_host/g" docker-compose.generated.yml
sed -i "s/__7__/$db_user@$db_host/g" docker-compose.generated.yml
sed -i "s/__8__/$db_pwd/g" docker-compose.generated.yml
echo "done."

echo -n "Generating Web App configuration..."
cp appSettings.azuread.json appSettings.generated.json
sed -i "s/__1__/$webapp/g" appSettings.generated.json
sed -i "s/__2__/$aad_app_id/g" appSettings.generated.json
sed -i "s/__3__/$aad_app_secret/g" appSettings.generated.json
sed -i "s/__4__/$aad_tenant_id/g" appSettings.generated.json
sed -i "s/__5__/$admin_pwd/g" appSettings.generated.json
sed -i "s/__6__/$db_host/g" appSettings.generated.json
sed -i "s/__7__/$db_user@$db_host/g" appSettings.generated.json
sed -i "s/__8__/$db_pwd/g" appSettings.generated.json
echo "done."

# Create Azure resources
echo -n "Creating resource group \"$rg\" in \"$location\"..."
az group create \
  -g $rg \
  -l $location \
  -o none
echo "done."

echo -n "Creating Azure Database for PostgreSQL..."
az postgres server create \
  -g $rg \
  -n $db_host \
  -l $location \
  --sku-name $postgresql_sku \
  --version 11 \
  --storage-size $postgresql_storage \
  --admin-user $db_user \
  --admin-password $db_pwd \
  --minimal-tls-version TLS1_2 \
  -o none
echo "done."

echo -n "Creating Grafana database..."
az postgres db create \
  -g $rg \
  -n grafana \
  -s $db_host \
  -o none
echo "done."

echo -n "Updating Azure Database firewall rules..."
current_ip=$(curl -s 'https://api.ipify.org?format=text')
az postgres server firewall-rule create \
  -g $rg \
  -n "from-host-$time_stamp" \
  -s $db_host \
  --start-ip-address $current_ip \
  --end-ip-address $current_ip \
  -o none
az postgres server firewall-rule create \
  -g $rg \
  -n all-azure \
  -s $db_host \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 \
  -o none
echo "done."

echo -n "Creating App Service plan \"$plan\" of size \"$appsvc_sku\"..."
az appservice plan create \
  -g $rg \
  -n $plan \
  -l $location \
  --is-linux \
  --sku $appsvc_sku \
  -o none
echo "done."

echo -n "Creating Web App \"$webapp\" using \"grafana/grafana:$tag\"..."
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
echo "done."

echo -n "Updating Web App configuration..."
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
echo "done."

echo "Setup complete. Open https://$webapp.azurewebsites.net or run \"docker-compose -f docker-compose.generated.yml\"."
