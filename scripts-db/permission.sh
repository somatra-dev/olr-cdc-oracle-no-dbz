#!/bin/bash
# This script runs after Oracle starts to fix permissions for OpenLogReplicator
# OpenLogReplicator needs read access to redo logs and datafiles

echo "Permissions for OpenLogReplicator access..."

chmod -R 755 /opt/oracle/oradata/ORCLCDB 2>/dev/null || true
chmod -R 755 /opt/oracle/fast_recovery_area 2>/dev/null || true

echo "Permissions updated successfully for OpenLogReplicator."
