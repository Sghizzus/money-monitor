#!/bin/bash
# ==============================================================
# Setup Azure Container App Job
# Usa GitHub Container Registry (GHCR) come image registry,
# eliminando la dipendenza da Azure Container Registry.
#
# Prerequisiti:
# - Azure CLI installata e autenticata (az login)
# - L'immagine deve essere già stata buildata da GitHub Actions
#   (push su main triggera il workflow docker-build.yml)
# - Il package GHCR deve essere impostato come pubblico su GitHub:
#   github.com/Sghizzus/money-monitor/pkgs/container/money-monitor
#   -> Package settings -> Change visibility -> Public
# ==============================================================

set -e

# --- Variabili ---
RESOURCE_GROUP="money-monitor-rg"
LOCATION_RG="westeurope"      # region del resource group già esistente
LOCATION="northeurope"        # region del Container App
ENV_NAME="money-monitor-env"
JOB_NAME="money-monitor-job"
IMAGE="ghcr.io/sghizzus/money-monitor:latest"

# Credenziali — non scrivere i valori qui: vengono letti dall'ambiente
DB_PWD="${DB_PWD}"
BBVA_USER="${BBVA_USER}"
BBVA_PASSWORD="${BBVA_PASSWORD}"

# --- 1. Resource Group (già esistente, idempotente) ---
echo ">>> Resource group..."
az group create \
  --name "$RESOURCE_GROUP" \
  --location "$LOCATION_RG"

# --- 2. Container Apps Environment ---
echo ">>> Creo il Container Apps Environment..."
az containerapp env create \
  --name "$ENV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION"

# --- 3. Container App Job (cron ogni 15 minuti) ---
echo ">>> Creo il Container App Job..."
az containerapp job create \
  --name "$JOB_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --environment "$ENV_NAME" \
  --trigger-type "Schedule" \
  --cron-expression "*/15 * * * *" \
  --replica-timeout 1800 \
  --image "$IMAGE" \
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

echo ""
echo ">>> Deploy completato."
echo "    Job:    $JOB_NAME"
echo "    Image:  $IMAGE"
echo ""
echo "Per aggiornare dopo modifiche al codice: basta fare push su main."
echo "GitHub Actions rebuilda l'immagine automaticamente."
