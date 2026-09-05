#!/bin/bash
# ==============================================================
# Setup Azure Container Registry + Container App Job
# Eseguire una volta sola per il deploy iniziale.
# Richiede Azure CLI installata e autenticata (az login).
# ==============================================================

set -e

# --- Variabili (modifica secondo necessità) ---
RESOURCE_GROUP="money-monitor-rg"
LOCATION="westeurope"
ACR_NAME="moneymonitoracr"          # solo lettere e numeri, unico globalmente
IMAGE_NAME="money-monitor"
IMAGE_TAG="latest"
ENV_NAME="money-monitor-env"
JOB_NAME="money-monitor-job"

# Credenziali — non scrivere i valori qui: vengono letti dall'ambiente
DB_PWD="${DB_PWD}"
BBVA_USER="${BBVA_USER}"
BBVA_PASSWORD="${BBVA_PASSWORD}"

# --- 1. Resource Group ---
echo ">>> Creo il resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION"

# --- 2. Azure Container Registry ---
echo ">>> Creo il Container Registry..."
az acr create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$ACR_NAME" \
  --sku Basic \
  --admin-enabled true

# --- 3. Build e push dell'immagine ---
echo ">>> Build e push dell'immagine Docker..."
az acr build \
  --registry "$ACR_NAME" \
  --image "$IMAGE_NAME:$IMAGE_TAG" \
  .

# --- 4. Container Apps Environment ---
echo ">>> Creo il Container Apps Environment..."
az containerapp env create \
  --name "$ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION"

# --- 5. Container App Job (cron ogni 15 minuti) ---
echo ">>> Creo il Container App Job..."

ACR_SERVER="${ACR_NAME}.azurecr.io"
ACR_PASSWORD=$(az acr credential show --name "$ACR_NAME" --query "passwords[0].value" -o tsv)

az containerapp job create \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --trigger-type "Schedule" \
  --cron-expression "*/15 * * * *" \
  --replica-timeout 1800 \
  --image "${ACR_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}" \
  --registry-server "$ACR_SERVER" \
  --registry-username "$ACR_NAME" \
  --registry-password "$ACR_PASSWORD" \
  --cpu 0.5 \
  --memory 1.0Gi \
  --secrets \
      "db-pwd=${DB_PWD}" \
      "bbva-user=${BBVA_USER}" \
      "bbva-password=${BBVA_PASSWORD}" \
  --env-vars \
      "DB_PWD=secretref:db-pwd" \
      "BBVA_USER=secretref:bbva-user" \
      "BBVA_PASSWORD=secretref:bbva-password"

echo ">>> Deploy completato."
echo "    Job: $JOB_NAME"
echo "    Immagine: ${ACR_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
echo ""
echo "Per aggiornare l'immagine dopo modifiche al codice:"
echo "  az acr build --registry $ACR_NAME --image $IMAGE_NAME:$IMAGE_TAG ."
echo "  az containerapp job update --name $JOB_NAME --resource-group $RESOURCE_GROUP --image ${ACR_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"
