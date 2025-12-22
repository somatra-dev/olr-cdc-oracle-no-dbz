-- =====================================================================
-- COMPLETE ORACLE SETUP FOR DEBEZIUM + OPENLOGREPLICATOR
-- Run as SYS AS SYSDBA connected to CDB (ORCLCDB)
-- =====================================================================
SET ECHO ON;
SET SERVEROUTPUT ON;
WHENEVER SQLERROR EXIT FAILURE;

-- 1. Enable ARCHIVELOG mode (safe: skips if already enabled)
DECLARE
v_log_mode VARCHAR2(10);
BEGIN
SELECT log_mode INTO v_log_mode FROM v$database;
IF v_log_mode != 'ARCHIVELOG' THEN
    EXECUTE IMMEDIATE 'SHUTDOWN IMMEDIATE';
EXECUTE IMMEDIATE 'STARTUP MOUNT';
EXECUTE IMMEDIATE 'ALTER DATABASE ARCHIVELOG';
EXECUTE IMMEDIATE 'ALTER DATABASE OPEN';
DBMS_OUTPUT.PUT_LINE('ARCHIVELOG mode enabled.');
ELSE
    DBMS_OUTPUT.PUT_LINE('ARCHIVELOG mode already enabled.');
END IF;
END;
/

-- Set recovery area size
ALTER SYSTEM SET db_recovery_file_dest_size = 10G SCOPE=BOTH;

-- Enable minimal supplemental logging (required for both LogMiner and OLR)
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

-- 2. Create LogMiner tablespace in CDB (idempotent)
BEGIN
EXECUTE IMMEDIATE 'CREATE TABLESPACE LOGMINER_TBS DATAFILE ''/opt/oracle/oradata/ORCLCDB/logminer_tbs.dbf'' SIZE 100M REUSE AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED';
DBMS_OUTPUT.PUT_LINE('LOGMINER_TBS tablespace created in CDB.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1543 THEN -- tablespace already exists
      DBMS_OUTPUT.PUT_LINE('LOGMINER_TBS tablespace already exists in CDB.');
ELSE
      RAISE;
END IF;
END;
/

-- Switch to PDB and create tablespace there
ALTER SESSION SET CONTAINER = ORCLPDB1;

BEGIN
EXECUTE IMMEDIATE 'CREATE TABLESPACE LOGMINER_TBS DATAFILE ''/opt/oracle/oradata/ORCLCDB/ORCLPDB1/logminer_tbs.dbf'' SIZE 100M REUSE AUTOEXTEND ON NEXT 100M MAXSIZE UNLIMITED';
DBMS_OUTPUT.PUT_LINE('LOGMINER_TBS tablespace created in PDB.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -1543 THEN
      DBMS_OUTPUT.PUT_LINE('LOGMINER_TBS tablespace already exists in PDB.');
ELSE
      RAISE;
END IF;
END;
/

-- Back to CDB
ALTER SESSION SET CONTAINER = CDB$ROOT;

-- 3. Create common user c##dbzuser (idempotent)
DECLARE
v_count NUMBER;
BEGIN
SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = 'C##DBZUSER';
IF v_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE USER c##dbzuser IDENTIFIED BY dbz
        DEFAULT TABLESPACE LOGMINER_TBS
        QUOTA UNLIMITED ON LOGMINER_TBS
        CONTAINER=ALL
    ]';
    DBMS_OUTPUT.PUT_LINE('User c##dbzuser created.');
ELSE
    DBMS_OUTPUT.PUT_LINE('User c##dbzuser already exists.');
END IF;
END;
/

-- 4. Grant permissions for c##dbzuser (CDB level)
GRANT CREATE SESSION TO c##dbzuser CONTAINER=ALL;
GRANT SET CONTAINER TO c##dbzuser CONTAINER=ALL;
GRANT CONNECT TO c##dbzuser;
GRANT RESOURCE TO c##dbzuser;

-- Database dictionary access
GRANT SELECT ON V_$DATABASE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$LOGFILE TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$ARCHIVED_LOG TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$PARAMETER TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON V_$TRANSACTION TO c##dbzuser CONTAINER=ALL;

-- LogMiner specific grants
GRANT SELECT ANY DICTIONARY TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ANY TRANSACTION TO c##dbzuser CONTAINER=ALL;
GRANT SELECT_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;

-- Table access grants (can be restricted to specific tables)
GRANT SELECT ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT FLASHBACK ANY TABLE TO c##dbzuser CONTAINER=ALL;
GRANT LOCK ANY TABLE TO c##dbzuser CONTAINER=ALL;

-- Dictionary tables access
GRANT SELECT ON DBA_OBJECTS TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON DBA_TABLES TO c##dbzuser CONTAINER=ALL;
GRANT SELECT ON DBA_TAB_COLUMNS TO c##dbzuser CONTAINER=ALL;

-- LogMiner dictionary grants
GRANT EXECUTE_CATALOG_ROLE TO c##dbzuser CONTAINER=ALL;
GRANT CREATE TABLE TO c##dbzuser CONTAINER=ALL;
GRANT CREATE SEQUENCE TO c##dbzuser CONTAINER=ALL;

-- 5. PDB-specific grants for both LogMiner and OpenLogReplicator
ALTER SESSION SET CONTAINER = ORCLPDB1;

-- OpenLogReplicator specific SYS table grants
GRANT SELECT, FLASHBACK ON SYS.CCOL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.CDEF$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.COL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.DEFERRED_STG$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.ECOL$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOB$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOBCOMPPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.LOBFRAG$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.OBJ$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TAB$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABCOMPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TABSUBPART$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.TS$ TO c##dbzuser;
GRANT SELECT, FLASHBACK ON SYS.USER$ TO c##dbzuser;

-- XDB table grants for OpenLogReplicator
GRANT SELECT, FLASHBACK ON XDB.XDB$TTSET TO c##dbzuser;

-- Grant on all XDB internal tables (dynamic names like X$NM*, X$PT*, X$QN*)
BEGIN
FOR t IN (
    SELECT owner, table_name
    FROM dba_tables
    WHERE owner = 'XDB'
    AND (table_name LIKE 'X$NM%'
         OR table_name LIKE 'X$PT%'
         OR table_name LIKE 'X$QN%'
         OR table_name LIKE 'X$%')
  ) LOOP
BEGIN
EXECUTE IMMEDIATE 'GRANT SELECT, FLASHBACK ON ' || t.owner || '."' || t.table_name || '" TO c##dbzuser';
DBMS_OUTPUT.PUT_LINE('Granted on: ' || t.owner || '.' || t.table_name);
EXCEPTION
      WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('Failed to grant on: ' || t.owner || '.' || t.table_name || ' - ' || SQLERRM);
END;
END LOOP;
END;
/

-- Additional LogMiner grants
GRANT EXECUTE ON DBMS_LOGMNR TO c##dbzuser;
GRANT EXECUTE ON DBMS_LOGMNR_D TO c##dbzuser;

-- 6. Create application schema and table
DECLARE
v_count NUMBER;
BEGIN
SELECT COUNT(*) INTO v_count FROM dba_users WHERE username = 'OLR_DB';
IF v_count = 0 THEN
    EXECUTE IMMEDIATE q'[
      CREATE USER olr_db IDENTIFIED BY olr_password
        DEFAULT TABLESPACE USERS
        QUOTA UNLIMITED ON USERS
        CONTAINER=CURRENT
    ]';
    DBMS_OUTPUT.PUT_LINE('User olr_db created.');
ELSE
    DBMS_OUTPUT.PUT_LINE('User olr_db already exists.');
END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, CREATE SEQUENCE TO olr_db;
GRANT CONNECT, RESOURCE TO olr_db;

-- 7. Create table and supplemental logging (as olr_db)
CONNECT olr_db/olr_password@ORCLPDB1;

BEGIN
EXECUTE IMMEDIATE q'[
    CREATE TABLE product (
      id NUMBER(10) GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
      name VARCHAR2(100) NOT NULL,
      description VARCHAR2(500),
      price NUMBER(10,2) NOT NULL,
      stock NUMBER(8) DEFAULT 0,
      created_date DATE DEFAULT SYSDATE,
      updated_date DATE DEFAULT SYSDATE
    )
  ]';
DBMS_OUTPUT.PUT_LINE('Table product created.');
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE = -955 THEN -- table already exists
      DBMS_OUTPUT.PUT_LINE('Table product already exists.');
ELSE
      RAISE;
END IF;
END;
/

-- Enable supplemental logging for the table
ALTER TABLE product ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- =====================================================================
-- NO SAMPLE DATA INSERTED
-- Table is empty - insert data AFTER CDC connector is running
-- to test real-time Change Data Capture
-- =====================================================================

-- 8. Grant table access to c##dbzuser
CONNECT / AS SYSDBA;
ALTER SESSION SET CONTAINER = ORCLPDB1;

GRANT SELECT, FLASHBACK ON olr_db.product TO c##dbzuser;

-- 9. Final verification
CONNECT c##dbzuser/dbz@ORCLPDB1;

PROMPT === Verification: Table structure ===
DESCRIBE olr_db.product;

PROMPT === Verification: Row count (should be 0) ===
SELECT COUNT(*) AS row_count FROM olr_db.product;

-- Back to SYS
CONNECT / AS SYSDBA;
ALTER SESSION SET CONTAINER = CDB$ROOT;

PROMPT =====================================================
PROMPT Setup completed successfully!
PROMPT =====================================================
PROMPT
PROMPT Table OLR_DB.PRODUCT created with NO initial data.
PROMPT
PROMPT After CDC connector is running, test with:
PROMPT
PROMPT   sqlplus olr_db/olr_password@ORCLPDB1
PROMPT
PROMPT   INSERT INTO product (name, description, price, stock)
PROMPT   VALUES ('Test Product', 'CDC Test', 99.99, 10);
PROMPT   COMMIT;
PROMPT
PROMPT   UPDATE product SET price = 149.99 WHERE id = 1;
PROMPT   COMMIT;
PROMPT
PROMPT   DELETE FROM product WHERE id = 1;
PROMPT   COMMIT;
PROMPT
PROMPT =====================================================