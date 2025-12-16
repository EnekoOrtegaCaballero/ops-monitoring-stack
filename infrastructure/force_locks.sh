#!/bin/bash
# Uso: DB_PASSWORD="TuPassword" ./force_locks.sh

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="${DB_PASSWORD:-StrongPass123!}"

echo "--- INICIANDO GUERRA DE BLOQUEOS ---"
echo "Simulando contención de recursos (Locks)..."

# Preparar terreno
docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
    IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB;
    USE TestDB;
    IF OBJECT_ID('LockWar', 'U') IS NOT NULL DROP TABLE LockWar;
    CREATE TABLE LockWar (ID INT, Val CHAR(10));
    INSERT INTO LockWar VALUES (1, 'Peace');
"

while true; do
    # 1. EL VILLANO (Bloquea la fila durante 5 segundos)
    docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
        USE TestDB;
        BEGIN TRAN;
            UPDATE LockWar SET Val = 'War' WHERE ID = 1;
            WAITFOR DELAY '00:00:05'; -- Retiene el bloqueo
        ROLLBACK;
    " > /dev/null 2>&1 &

    sleep 1

    # 2. LAS VÍCTIMAS (Intentan leer y fallan por Timeout)
    for i in {1..5}; do
        docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
            USE TestDB;
            SET LOCK_TIMEOUT 2000; -- Ríndete a los 2s (Genera Timeout)
            SELECT * FROM LockWar WHERE ID = 1;
        " > /dev/null 2>&1 &
    done

    wait
    echo -n "🔒"
done
