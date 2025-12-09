#!/bin/bash
# setup_vps.sh
# Script para aprovisionar VPS Ubuntu 24.04 con Docker y Tailscale

set -e

echo ">>> [1/5] Actualizando sistema..."
sudo apt update && sudo apt upgrade -y

echo ">>> [2/5] Instalando utilidades base..."
sudo apt install -y curl git htop ufw unzip acl tree

echo ">>> [3/5] Configurando Firewall (UFW)..."
sudo ufw allow ssh
sudo ufw allow 41641/udp
# Habilitamos firewall (requiere confirmación "y" si no se usa --force, usamos force para automatizar)
sudo ufw --force enable

echo ">>> [4/5] Instalando Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh
    sudo usermod -aG docker $USER
    rm get-docker.sh
    echo "Docker instalado correctamente."
else
    echo "Docker ya estaba instalado."
fi

echo ">>> [5/5] Instalando Tailscale..."
if ! command -v tailscale &> /dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
    echo "Tailscale instalado."
else
    echo "Tailscale ya estaba instalado."
fi

echo ">>> Creando directorios de persistencia en /opt/..."
sudo mkdir -p /opt/monitoring/{zabbix-db,grafana-data,loki-data}
sudo chown -R 1000:1000 /opt/monitoring

echo ">>> ¡INSTALACIÓN COMPLETADA!"
echo "AVISO: Cierra sesión y vuelve a entrar para usar Docker sin sudo."
echo "AVISO: Ejecuta 'sudo tailscale up' para conectar a la VPN."
