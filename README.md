# Stack de Observabilidad Unificado (Zabbix + Loki + Grafana)

Este repositorio contiene la infraestructura como código (IaC) para desplegar un sistema de monitoreo ligero y seguro, diseñado para operar en VPS de recursos limitados (OVH) y monitorear entornos híbridos (AWS/On-Premise) mediante Tailscale.

## 🚀 Componentes

* **Zabbix 7.0:** Recolección de métricas eficiente (CPU, RAM, SQL Server).
* **Grafana Loki:** Ingesta y agregación de logs sin indexación pesada.
* **Promtail:** Agente de recolección de logs (incluye logs de seguridad/SIEM).
* **Grafana:** Visualización unificada.
* **Tailscale:** Red mallada VPN para conectar componentes de forma segura.

## 🛠️ Despliegue Rápido

1.  **Clonar el repositorio en el VPS:**
    ```bash
    git clone [https://github.com/TU_USUARIO/ops-monitoring-stack.git](https://github.com/TU_USUARIO/ops-monitoring-stack.git)
    cd ops-monitoring-stack
    ```

2.  **Ejecutar script de aprovisionamiento (Solo primera vez):**
    ```bash
    chmod +x scripts/setup_vps.sh
    ./scripts/setup_vps.sh
    ```
    *Esto instala Docker, Tailscale y crea las carpetas necesarias.*

3.  **Configurar entorno:**
    Crear un archivo `.env` basado en el ejemplo:
    ```bash
    cp .env.example .env
    nano .env # (Editar contraseñas)
    ```

4.  **Iniciar servicios:**
    ```bash
    docker compose up -d
    ```

## 🔐 Seguridad (SIEM Básico)
El stack incluye configuración para ingerir logs de `/var/log/auth.log` del host, permitiendo detectar intentos de intrusión SSH directamente desde Grafana aunque en este caso concreto, no habrá tales ya que no esta abierto puerto al conectarme por VPN.

## 📂 Estructura
* `/configs`: Archivos de configuración de servicios (inyectados vía volumen).
* `/scripts`: Automatización del SO.
