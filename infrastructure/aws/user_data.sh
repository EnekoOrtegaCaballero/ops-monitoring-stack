#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> [INIT] Iniciando configuración automática del Lab..."

# 1. Variables inyectadas por Terraform (Ahora incluye la password)
TAILSCALE_AUTH_KEY="${TAILSCALE_KEY}"
VPS_MONITORING_IP="${VPS_IP}"
SA_PASSWORD="${DB_PASSWORD}"  # <-- Terraform sustituirá esto por el valor real

# 2. Instalación de Docker y Herramientas
echo ">>> [INSTALL] Docker & Dependencies"
apt-get update
apt-get install -y curl apt-transport-https ca-certificates software-properties-common gnupg lsb-release

# Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
apt-get install -y docker-compose-plugin

# 3. Instalación y Conexión de Tailscale
echo ">>> [NET] Configurando Tailscale VPN"
curl -fsSL https://tailscale.com/install.sh | sh
sysctl -w net.ipv4.ip_forward=1
tailscale up --authkey=$TAILSCALE_AUTH_KEY --hostname=aws-sql-target --accept-routes

# 4. Preparar Directorio
mkdir -p /opt/lab/promtail
cd /opt/lab

# 5. Configurar Promtail
cat <<YAML > /opt/lab/promtail/config.yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://$VPS_MONITORING_IP:3100/loki/api/v1/push
scrape_configs:
  - job_name: sql_server
    static_configs:
      - targets:
          - localhost
        labels:
          job: mssql_logs
          instance: aws-ec2-target
          __path__: /var/lib/docker/containers/*/*-json.log
    pipeline_stages:
      - docker: {}
YAML

# 6. Generar docker-compose.yml
echo ">>> [DOCKER] Generando docker-compose.yml"
cat <<YAML > docker-compose.yml
version: '3.8'
services:
  sql-server:
    image: mcr.microsoft.com/mssql/server:2022-latest
    container_name: sql-server
    restart: always
    environment:
      - ACCEPT_EULA=Y
      - MSSQL_SA_PASSWORD=$SA_PASSWORD
      - MSSQL_PID=Developer
    ports:
      - "1433:1433"
    deploy:
      resources:
        limits:
          memory: 2G

  zabbix-agent:
    image: zabbix/zabbix-agent2:7.0-alpine
    container_name: zabbix-agent
    restart: always
    privileged: true
    user: root
    network_mode: "host"
    environment:
      - ZBX_HOSTNAME=AWS-SQL-Target
      - ZBX_SERVER=$VPS_MONITORING_IP
      - ZBX_SERVERACTIVE=$VPS_MONITORING_IP
      - ZBX_HOSTMETADATA=Linux SQLServer
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock

  promtail:
    image: grafana/promtail:2.9.0
    container_name: promtail
    restart: always
    command: -config.file=/etc/promtail/config.yaml
    volumes:
      - /opt/lab/promtail/config.yaml:/etc/promtail/config.yaml
      - /var/lib/docker/containers:/var/lib/docker/containers:ro
      - /var/run/docker.sock:/var/run/docker.sock

  chaos-monkey:
    image: polinux/stress-ng
    container_name: chaos-monkey
    command: --cpu 2 --timeout 60s
    deploy:
      replicas: 0
YAML

# 7. Arrancar
echo ">>> [START] Levantando contenedores..."
docker compose up -d
echo ">>> [DONE] Setup finalizado."
