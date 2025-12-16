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
# CORRECCIÓN 1: Aseguramos que lea la config del plugin MSSQL
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
# CRÍTICO: Carga recursiva de plugins (donde vive mssql.conf)
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
# CORRECCIÓN 2: Imagen Ubuntu, Sin comillas en pass y Límite de CPU
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
      # IMPORTANTE: Sin comillas para evitar errores de parsing en SQL Server
      - MSSQL_SA_PASSWORD=$SA_PASSWORD
      - MSSQL_PID=Developer
    ports:
      - "1433:1433"
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '1.0' # MEJORA: Limitamos a 1 CPU para que los tests no congelen la máquina

  zabbix-agent:
    # Usamos la imagen Ubuntu que trae el plugin nativo preinstalado
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

# 7. GENERACIÓN DE SCRIPTS DE PRUEBA (NUEVO)
echo ">>> [TESTS] Generando scripts de validación en /opt/lab/tests..."
mkdir -p /opt/lab/tests

# Script A: Carga General (CPU + Transacciones)
cat <<EOF > /opt/lab/tests/load_test.sh
#!/bin/bash
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
# Si no se pasa pass por env, usa la de Terraform por defecto
PASS="\${DB_PASSWORD:-$SA_PASSWORD}"

echo "--- INICIANDO CARGA GENERAL ---"
while true; do
    for i in {1..5}; do
        docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
            SET NOCOUNT ON;
            IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB;
            USE TestDB;
            IF OBJECT_ID('LoadTable', 'U') IS NULL CREATE TABLE LoadTable (ID INT IDENTITY, Payload CHAR(100));
            DECLARE @i INT = 0;
            WHILE @i < 500
            BEGIN
                INSERT INTO LoadTable (Payload) VALUES ('Carga-' + CAST(@i AS VARCHAR));
                SELECT COUNT(*) FROM sys.objects A CROSS JOIN sys.objects B;
                DELETE FROM LoadTable WHERE ID = SCOPE_IDENTITY();
                SET @i = @i + 1;
            END
        " > /dev/null 2>&1 &
    done
    wait
    echo -n "🔥"
done
EOF

# Script B: Guerra de Bloqueos (Agresivo)
cat <<EOF > /opt/lab/tests/force_locks.sh
#!/bin/bash
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="\${DB_PASSWORD:-$SA_PASSWORD}"

echo "--- PREPARANDO GUERRA DE BLOQUEOS ---"
docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
    IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB;
"
docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
    USE TestDB;
    IF OBJECT_ID('LockWar', 'U') IS NOT NULL DROP TABLE LockWar;
    CREATE TABLE LockWar (ID INT, Val CHAR(10));
    INSERT INTO LockWar VALUES (1, 'Peace');
"

echo "--- INICIANDO BLOQUEOS (UPDATE vs UPDATE) ---"
while true; do
    # Villano
    docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
        USE TestDB; BEGIN TRAN; UPDATE LockWar SET Val = 'War' WHERE ID = 1; WAITFOR DELAY '00:00:05'; ROLLBACK;
    " > /dev/null 2>&1 &
    sleep 1
    # Víctimas
    for i in {1..5}; do
        docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
            USE TestDB; SET LOCK_TIMEOUT 2000; UPDATE LockWar SET Val = 'Victim' WHERE ID = 1;
        " > /dev/null 2>&1 &
    done
    wait
    echo -n "🔒"
done
EOF

# Script C: Trigger Deadlock
cat <<EOF > /opt/lab/tests/trigger_deadlock.sh
#!/bin/bash
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="\${DB_PASSWORD:-$SA_PASSWORD}"
echo "--- PROVOCANDO DEADLOCK ---"
docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
    IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB; USE TestDB;
    IF OBJECT_ID('TableA') IS NULL CREATE TABLE TableA (ID INT);
    IF OBJECT_ID('TableB') IS NULL CREATE TABLE TableB (ID INT);
    DELETE FROM TableA; DELETE FROM TableB; INSERT INTO TableA VALUES (1); INSERT INTO TableB VALUES (1);
"
docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
    USE TestDB; BEGIN TRAN; UPDATE TableA SET ID = 2; WAITFOR DELAY '00:00:05'; UPDATE TableB SET ID = 2; COMMIT;
" > /dev/null 2>&1 &
docker exec sql-server \$SQLCMD -S localhost -U sa -P "\$PASS" \$FLAGS -Q "
    USE TestDB; BEGIN TRAN; UPDATE TableB SET ID = 2; WAITFOR DELAY '00:00:05'; UPDATE TableA SET ID = 2; COMMIT;
" > /dev/null 2>&1 &
echo "Deadlock lanzado."
EOF

chmod +x /opt/lab/tests/*.sh

# 8. Arrancar Servicios
echo ">>> [START] Levantando contenedores..."
docker compose up -d

# 9. AUTO-CONFIGURACIÓN VÍA API DE ZABBIX (Python Script)
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

    # 4. Crear/Actualizar Macros (CORRECCIÓN 3: PROTOCOLO SQLSERVER Y SSL)
    # Aqui estaba el fallo principal: 'tcp://' ya no sirve y faltaba 'trustServerCertificate'
    macros = [
        {"macro": "{\$MSSQL.URI}", "value": "sqlserver://127.0.0.1:1433?trustServerCertificate=true"},
        {"macro": "{\$MSSQL.USER}", "value": "sa"},
        {"macro": "{\$MSSQL.PASSWORD}", "value": MSSQL_PASS},
        {"macro": "{\$MSSQL.HOST}", "value": HOST_IP},
        {"macro": "{\$MSSQL.PORT}", "value": "1433"}
    ]
    
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
