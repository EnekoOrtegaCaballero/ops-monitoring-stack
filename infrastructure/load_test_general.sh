#!/bin/bash
# Uso: DB_PASSWORD="TuPassword" ./load_test_general.sh

# Configuración
SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C" # Confiar en certificado (Necesario para SQL 2022)
PASS="${DB_PASSWORD:-StrongPass123!}" # Usa variable de entorno o valor por defecto

echo "--- INICIANDO CARGA GENERAL (CPU + Transacciones) ---"
echo "Simulando tráfico web intenso..."

# Bucle infinito
while true; do
    # Lanzamos 5 clientes concurrentes
    for i in {1..5}; do
        docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
            SET NOCOUNT ON;
            IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB;
            USE TestDB;
            IF OBJECT_ID('LoadTable', 'U') IS NULL CREATE TABLE LoadTable (ID INT IDENTITY, Payload CHAR(100));
            
            -- Bucle interno: 1000 operaciones por conexión
            DECLARE @i INT = 0;
            WHILE @i < 1000
            BEGIN
                -- 1. INSERT (Genera Log Flushes y Transactions/sec)
                INSERT INTO LoadTable (Payload) VALUES ('Carga-' + CAST(@i AS VARCHAR));
                
                -- 2. SELECT PESADO (Genera CPU y Batch Requests)
                SELECT COUNT(*) FROM sys.objects A CROSS JOIN sys.objects B;
                
                -- 3. DELETE (Mantiene el tamaño controlado)
                DELETE FROM LoadTable WHERE ID = SCOPE_IDENTITY();
                
                SET @i = @i + 1;
            END
        " > /dev/null 2>&1 &
    done

    # Esperamos a que terminen estos 5 hilos antes de lanzar más
    wait
    echo -n "🔥"
done
