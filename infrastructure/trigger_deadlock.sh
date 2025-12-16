#!/bin/bash
# Ejecutar una vez para ver el pico en la gráfica

SQLCMD="/opt/mssql-tools18/bin/sqlcmd"
FLAGS="-C"
PASS="${DB_PASSWORD:-StrongPass123!}"

echo "--- PROVOCANDO DEADLOCK ---"

# Preparar tablas
docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
    IF DB_ID('TestDB') IS NULL CREATE DATABASE TestDB;
    USE TestDB;
    IF OBJECT_ID('TableA') IS NULL CREATE TABLE TableA (ID INT);
    IF OBJECT_ID('TableB') IS NULL CREATE TABLE TableB (ID INT);
    DELETE FROM TableA; DELETE FROM TableB;
    INSERT INTO TableA VALUES (1); INSERT INTO TableB VALUES (1);
"

# Proceso A (Quiere A -> Espera -> Quiere B)
docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
    USE TestDB;
    BEGIN TRAN;
    UPDATE TableA SET ID = 2;
    WAITFOR DELAY '00:00:05';
    UPDATE TableB SET ID = 2; -- Choque aquí
    COMMIT;
" > /dev/null 2>&1 &

# Proceso B (Quiere B -> Espera -> Quiere A)
docker exec sql-server $SQLCMD -S localhost -U sa -P "$PASS" $FLAGS -Q "
    USE TestDB;
    BEGIN TRAN;
    UPDATE TableB SET ID = 2;
    WAITFOR DELAY '00:00:05';
    UPDATE TableA SET ID = 2; -- Choque aquí
    COMMIT;
" > /dev/null 2>&1 &

echo "Deadlock lanzado. Revisa Grafana."
