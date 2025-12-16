#!/bin/bash
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> [INIT] Iniciando configuración automática del Lab..."

# 1. Variables inyectadas por Terraform
TAILSCALE_AUTH_KEY="${TAILSCALE_KEY}"
VPS_MONITORING_IP="${VPS_IP}"
SA_PASSWORD="${DB_PASSWORD}"
ZABBIX_USER="${ZABBIX_USER}"
ZABBIX_PASS="${ZABBIX_PASS}"
HOSTNAME="AWS-SQL-Target"

# 2. Instalación de Docker, Python y Herramientas
echo ">>> [INSTALL] Docker & Dependencies"
apt-get update
apt-get install -y curl apt-transport-https ca-certificates software-properties-common gnupg lsb-release python3-pip jq

# Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sh get-docker.sh
apt-get install -y docker-compose-plugin

# 3. Instalación y Conexión de Tailscale
echo ">>> [NET] Configurando Tailscale VPN"
curl -fsSL https://tailscale.com/install.sh | sh
sysctl -w net.ipv4.ip_forward=1
tailscale up --authkey=$TAILSCALE_AUTH_KEY --hostname=aws-sql-target --accept-routes

# Obtener mi IP de Tailscale dinámicamente
MY_TS_IP=$(tailscale ip -4)
echo ">>> [NET] Mi IP de Tailscale es: $MY_TS_IP"

# 4. Configurar Agente Zabbix
  # CORRECCIÓN 1: Incluimos explícitamente la carpeta de plugins
  mkdir -p /opt/lab
  cat <<CONF > /opt/lab/zabbix_agent2.conf
  PidFile=/tmp/zabbix_agent2.pid
  LogType=console
  Server=$VPS_MONITORING_IP
  ServerActive=$VPS_MONITORING_IP
  Hostname=$HOSTNAME
  HostMetadata=Linux SQLServer
  ControlSocket=/tmp/agent.sock
  # Carga de configs generales
  Include=/etc/zabbix/zabbix_agent2.d/*.conf
  # IMPORTANTE: Carga recursiva de plugins (donde vive mssql.conf)
  Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
CONF

# 5. Configurar Promtail
mkdir -p /opt/lab/promtail
cd /opt/lab
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

# 6. Generar docker-compose.yml
  # CORRECCIÓN 2: Imagen Ubuntu, Sin comillas en pass, Sin volúmenes extraños
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
        # OJO: Sin comillas aqui para evitar problemas de parsing
        - MSSQL_SA_PASSWORD=$SA_PASSWORD
        - MSSQL_PID=Developer
      ports:
        - "1433:1433"
      deploy:
        resources:
          limits:
            memory: 2G

    zabbix-agent:
      # Usamos la imagen Ubuntu que trae el plugin nativo
      image: zabbix/zabbix-agent2:ubuntu-7.0-latest
      container_name: zabbix-agent
      restart: always
      privileged: true
      user: root
      network_mode: "host"
      environment:
        - ZBX_HOSTNAME=$HOSTNAME
        - ZBX_SERVER=$VPS_MONITORING_IP
        - ZBX_SERVERACTIVE=$VPS_MONITORING_IP
        # Forzamos carga del modulo por seguridad
        - ZBX_LOADMODULE=zabbix-agent2-plugin-mssql
      volumes:
        - /var/run/docker.sock:/var/run/docker.sock
        - ./zabbix_agent2.conf:/etc/zabbix/zabbix_agent2.conf

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

# 7. Arrancar Servicios
echo ">>> [START] Levantando contenedores..."
docker compose up -d

# 8. AUTO-CONFIGURACIÓN VÍA API DE ZABBIX (Python Script)
# Esperamos un poco para asegurar que el agente se ha registrado
echo ">>> [API] Esperando 30s para auto-registro..."
sleep 30

cat <<EOF > /opt/lab/configure_zabbix.py
import requests
import json
import sys

# Configuración
ZABBIX_URL = "http://$VPS_MONITORING_IP:8080/api_jsonrpc.php"
USER = "$ZABBIX_USER"
PASSWORD = "$ZABBIX_PASS"
HOST_NAME = "$HOSTNAME"
HOST_IP = "$MY_TS_IP"
MSSQL_PASS = "$SA_PASSWORD"

def api_call(method, params, auth=None):
    payload = {
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": 1,
        "auth": auth
    }
    headers = {'Content-Type': 'application/json'}
    response = requests.post(ZABBIX_URL, data=json.dumps(payload), headers=headers)
    return response.json()

try:
    print(f"Connecting to Zabbix API at {ZABBIX_URL}...")
    
    # 1. Login
    login = api_call("user.login", {"username": USER, "password": PASSWORD})
    if 'error' in login:
        print(f"Login failed: {login['error']}")
        sys.exit(1)
    auth_token = login['result']
    print("Login success.")

    # 2. Obtener Host ID
    host_info = api_call("host.get", {"filter": {"host": [HOST_NAME]}}, auth_token)
    if not host_info['result']:
        print("Host not found yet. Auto-registration might be delayed.")
        sys.exit(1)
    
    host_id = host_info['result'][0]['hostid']
    print(f"Found Host ID: {host_id}")

    # 3. Actualizar Interfaz (Forzar IP de Tailscale y Puerto 10050)
    # Primero obtenemos la interfaz actual
    interface_info = api_call("hostinterface.get", {"hostids": host_id}, auth_token)
    if interface_info['result']:
        interface_id = interface_info['result'][0]['interfaceid']
        
        update_interface = api_call("hostinterface.update", {
            "interfaceid": interface_id,
            "useip": 1,
            "ip": HOST_IP,
            "dns": "",
            "port": "10050",
            "main": 1
        }, auth_token)
        print(f"Interface updated to {HOST_IP}: {update_interface}")

    # 4. Crear/Actualizar Macros (Credenciales SQL)
    macros = [
        {"macro": "{\$MSSQL.URI}", "value": f"tcp://{HOST_IP}:1433"},
        {"macro": "{\$MSSQL.USER}", "value": "sa"},
        {"macro": "{\$MSSQL.PASSWORD}", "value": MSSQL_PASS},
        {"macro": "{\$MSSQL.HOST}", "value": HOST_IP},
        {"macro": "{\$MSSQL.PORT}", "value": "1433"}
    ]
    
    # Hay que borrarlas primero si existen (para evitar duplicados) o usar host.update
    # Usaremos host.update para inyectar macros
    update_macros = api_call("host.update", {
        "hostid": host_id,
        "macros": macros
    }, auth_token)
    print(f"Macros updated: {update_macros}")

except Exception as e:
    print(f"Error: {e}")
EOF

# Ejecutar el script de Python
echo ">>> [API] Ejecutando script de configuración..."
python3 /opt/lab/configure_zabbix.py

echo ">>> [DONE] Setup finalizado."
EOF
