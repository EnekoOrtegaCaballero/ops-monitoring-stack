#!/bin/bash
# user_data.sh - Versión Final Consolidada (Infraestructura Corregida + Tests Originales)
exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1

echo ">>> [INIT] Iniciando configuración..."

# 1. Variables de Terraform
TAILSCALE_AUTH_KEY="${TAILSCALE_KEY}"
VPS_MONITORING_IP="${VPS_IP}"
SA_PASSWORD="${DB_PASSWORD}"
ZABBIX_USER="${ZABBIX_USER}"
ZABBIX_PASS="${ZABBIX_PASS}"
HOSTNAME_BASE="aws-sql-target"

# 2. Docker y Dependencias
echo ">>> [INSTALL] Docker..."
apt-get update && apt-get install -y curl apt-transport-https ca-certificates software-properties-common gnupg lsb-release python3-pip jq
curl -fsSL https://get.docker.com -o get-docker.sh && sh get-docker.sh
apt-get install -y docker-compose-plugin

# 3. Tailscale con ESPERA ACTIVA (Fix Race Condition)
echo ">>> [NET] Configurando Tailscale..."
curl -fsSL https://tailscale.com/install.sh | sh
sysctl -w net.ipv4.ip_forward=1
# Intentamos conectar. Si el nombre existe, Tailscale asignará uno nuevo
tailscale up --authkey=$TAILSCALE_AUTH_KEY --hostname=$HOSTNAME_BASE --accept-routes

# Bucle de espera hasta tener IP real
echo ">>> [NET] Esperando asignación de IP..."
MY_TS_IP=""
count=0
while [ -z "$MY_TS_IP" ] && [ $count -lt 30 ]; do
    MY_TS_IP=$(tailscale ip -4 2>/dev/null)
    [ -z "$MY_TS_IP" ] && sleep 2 && ((count++))
done

if [ -z "$MY_TS_IP" ]; then
    echo "!!! [ERROR] No se obtuvo IP de Tailscale. Fallo crítico."
    # Fallback de emergencia para no romper el script completo, aunque Zabbix fallará
    MY_TS_IP="127.0.0.1" 
fi

# Obtener nombre real asignado por Tailscale (ej: aws-sql-target-1)
MY_REAL_HOSTNAME=$(tailscale status --json | jq -r .Self.HostName)
echo ">>> [NET] IP: $MY_TS_IP | Hostname Real: $MY_REAL_HOSTNAME"

# 4. Config Zabbix (CON LISTEN IP FORZADA y SIN VARIABLES DE ENTORNO)
mkdir -p /opt/lab
cat <<CONF > /opt/lab/zabbix_agent2.conf
PidFile=/tmp/zabbix_agent2.pid
LogType=console
# Forzamos que el agente sepa su IP de VPN para evitar que reporte la 172.18.x.x
SourceIP=$MY_TS_IP
ListenIP=$MY_TS_IP
Server=$VPS_MONITORING_IP
ServerActive=$VPS_MONITORING_IP
Hostname=$MY_REAL_HOSTNAME
HostMetadata=Linux SQLServer
ControlSocket=/tmp/agent.sock
Include=/etc/zabbix/zabbix_agent2.d/*.conf
Include=/etc/zabbix/zabbix_agent2.d/plugins.d/*.conf
CONF

# 5. Promtail
mkdir -p /opt/lab/promtail
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
          instance: $MY_REAL_HOSTNAME
          __path__: /var/lib/docker/containers/*/*-json.log
    pipeline_stages:
      - docker: {}
YAML

# 6. Docker Compose (FIX: Read-Only Volume y Eliminación de ENV conflictivos)
echo ">>> [DOCKER] Generando compose..."
cat <<YAML > /opt/lab/docker-compose.yml
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
      - "$MY_TS_IP:1433:1433"
    deploy:
      resources:
        limits:
          memory: 2G
          cpus: '1.0'

  zabbix-agent:
    image: zabbix/zabbix-agent2:ubuntu-7.0-latest
    container_name: zabbix-agent
    restart: always
    privileged: true
    user: root
    network_mode: "host"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      # FIX: :ro evita que el contenedor intente editar el archivo y falle con "busy"
      - /opt/lab/zabbix_agent2.conf:/etc/zabbix/zabbix_agent2.conf:ro

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

# 7. SCRIPTS DE PRUEBA (Tus scripts originales restaurados)
echo ">>> [TESTS] Restaurando scripts de validación..."
mkdir -p /opt/lab/tests

# Script A: Carga General
cat <<EOF > /opt/lab/tests/load_test.sh
#!/bin/bash
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="$SA_PASSWORD"

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

# Script B: Guerra de Bloqueos
cat <<EOF > /opt/lab/tests/force_locks.sh
#!/bin/bash
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="$SA_PASSWORD"

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
PASS="$SA_PASSWORD"
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
cd /opt/lab
docker compose up -d

# 9. API FIX (Corrección de IP Agresiva y Auto-creación con RETRIES)
echo ">>> [API] Iniciando configuración de Zabbix..."
# Damos un margen de seguridad para que la red se estabilice
sleep 10

cat <<EOF > /opt/lab/configure_zabbix.py
import requests
import json
import sys
import time

ZABBIX_URL = "http://$VPS_MONITORING_IP:8080/api_jsonrpc.php"
USER = "$ZABBIX_USER"
PASSWORD = "$ZABBIX_PASS"
HOST_NAME = "$MY_REAL_HOSTNAME"
HOST_IP = "$MY_TS_IP"
MSSQL_PASS = "$SA_PASSWORD"

def api_call(method, params, auth=None):
    payload = {"jsonrpc": "2.0", "method": method, "params": params, "id": 1, "auth": auth}
    try:
        response = requests.post(ZABBIX_URL, data=json.dumps(payload), headers={'Content-Type': 'application/json'}, timeout=5)
        return response.json()
    except Exception as e:
        print(f"   [!] Connection warning: {e}")
        return {}

# --- LÓGICA DE LOGIN ROBUSTA (RETRIES) ---
auth = None
max_retries = 10
print(f"Connecting to API at {ZABBIX_URL}...")

for i in range(max_retries):
    print(f" -> Login attempt {i+1}/{max_retries}...")
    login = api_call("user.login", {"username": USER, "password": PASSWORD})
    
    if 'result' in login:
        auth = login['result']
        print(" -> Login Success!")
        break
    elif 'error' in login:
        print(f" -> Login denied: {login['error']}")
        sys.exit(1) # Si es error de usuario/pass, salir, no reintentar
    else:
        # Si es error de conexión (devuelve {}), esperamos y reintentamos
        time.sleep(5)

if not auth:
    print("!!! Critical: Could not connect to Zabbix API after multiple attempts.")
    sys.exit(1)

# --- FIN LÓGICA DE LOGIN ---

# Bucle para encontrar el host
host_id = None
for i in range(5):
    print(f"Searching host... attempt {i+1}")
    h_info = api_call("host.get", {"filter": {"host": [HOST_NAME]}}, auth)
    if h_info.get('result'):
        host_id = h_info['result'][0]['hostid']
        print(f"Host Found: {host_id}")
        break
    time.sleep(3)

if not host_id:
    print("Host not found after check. Creating manually.")
    create = api_call("host.create", {
        "host": HOST_NAME,
        "groups": [{"groupid": "2"}],
        "interfaces": [{"type": 1, "main": 1, "useip": 1, "ip": HOST_IP, "dns": "", "port": "10050"}],
        "templates": [{"templateid": "10001"}]
    }, auth)
    if 'result' in create:
        host_id = create['result']['hostids'][0]

# ACTUALIZACIÓN FORZOSA DE LA INTERFAZ
if host_id:
    iface = api_call("hostinterface.get", {"hostids": host_id}, auth)
    if iface.get('result'):
        iface_id = iface['result'][0]['interfaceid']
        print(f"Updating Interface {iface_id} to {HOST_IP}")
        api_call("hostinterface.update", {
            "interfaceid": iface_id,
            "useip": 1,
            "ip": HOST_IP, 
            "dns": "",
            "port": "10050",
            "main": 1
        }, auth)

    # Macros MSSQL (AQUI ESTA LA MAGIA QUE ARREGLA TU ERROR)
    print("Updating Macros...")
    macros = [
        {"macro": "{\$MSSQL.URI}", "value": "sqlserver://127.0.0.1:1433?trustServerCertificate=true"},
        {"macro": "{\$MSSQL.USER}", "value": "sa"},
        {"macro": "{\$MSSQL.PASSWORD}", "value": MSSQL_PASS},
        {"macro": "{\$MSSQL.HOST}", "value": HOST_IP},
        {"macro": "{\$MSSQL.PORT}", "value": "1433"}
    ]
    api_call("host.update", {"hostid": host_id, "macros": macros}, auth)
    print("Configuration Complete.")
EOF

python3 /opt/lab/configure_zabbix.py
echo ">>> [DONE] Setup finalizado."
