#!/bin/bash
# This script runs after Oracle starts to fix permissions for OpenLogReplicator
# OpenLogReplicator needs read access to redo logs, datafiles, and archive logs

echo "Setting initial permissions for OpenLogReplicator access..."

chmod -R 755 /opt/oracle/oradata/ORCLCDB 2>/dev/null || true
chmod -R 755 /opt/oracle/fast_recovery_area 2>/dev/null || true

# Fix archive log permissions specifically
chmod 644 /opt/oracle/oradata/ORCLCDB/archive_logs/*.dbf 2>/dev/null || true

echo "Initial permissions updated successfully for OpenLogReplicator."

# Start background job to continuously fix archive log permissions
# This is needed because Oracle creates new archive logs with 640 permissions
echo "Starting background permission fixer for archive logs..."

(
    while true; do
        # Fix permissions on all archive logs every 30 seconds
        chmod 644 /opt/oracle/oradata/ORCLCDB/archive_logs/*.dbf 2>/dev/null || true
        chmod 644 /opt/oracle/fast_recovery_area/ORCLCDB/archivelog/*/*.dbf 2>/dev/null || true
        sleep 30
    done
) &

echo "Background archive log permission fixer started (PID: $!)"
