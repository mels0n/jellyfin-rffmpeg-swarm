#!/bin/bash

# Prevent files/subdirectories from being created that are unreachable by remote rffmpeg workers
umask 002

# Function to print messages with timestamps
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}
log "Starting rffmpeg-worker container..."

# Function to handle cleanup on exit
cleanup() {
  log "Received stop signal. Cleaning up..."
  if [ -n "$SSHD_PID" ]; then
    kill -TERM "$SSHD_PID" 2>/dev/null
  fi
  if [ -n "$UPDATE_PID" ]; then
    kill -TERM "$UPDATE_PID" 2>/dev/null
  fi
  exit 0
}

trap cleanup SIGTERM SIGINT

# Function to log a critical error and exit
bail() {
  log "CRITICAL: $1"
  exit 1
}

# Set up SSH authorized_keys from Docker secret
if [ -f /run/secrets/rffmpeg_id_rsa_pub ]; then
    log "INFO: Configuring authorized_keys for transcodessh user."
    mkdir -p /home/transcodessh/.ssh
    cp /run/secrets/rffmpeg_id_rsa_pub /home/transcodessh/.ssh/authorized_keys
    chown -R transcodessh:users /home/transcodessh/.ssh
    chmod 700 /home/transcodessh/.ssh
    chmod 600 /home/transcodessh/.ssh/authorized_keys
fi

# Add transcodessh user to the group that owns renderD128
if [ -e /dev/dri/renderD128 ]; then
    renderD128_gid=$(stat -c "%g" /dev/dri/renderD128)
    # Check if a group with this GID already exists. If not, create it.
    if ! getent group "$renderD128_gid" >/dev/null; then
        groupadd --gid "$renderD128_gid" render
    fi
    usermod -aG "$renderD128_gid" transcodessh
    log "transcodessh user was added to render group ($renderD128_gid)"
else
    log "Warning: /dev/dri/renderD128 not found. Skipping GPU group setup."
fi

# --- OpenCL Verification ---
export LD_LIBRARY_PATH="/opt/intel/legacy-opencl:$LD_LIBRARY_PATH"
log "Checking OpenCL Status..."
if command -v clinfo > /dev/null; then
    clinfo | grep "Platform Name" || echo "No OpenCL platforms found."
else
    log "Warning: clinfo not found."
fi
log "OpenCL Check Complete."

# Determine the NFS server hostname based on the worker's own hostname.
# If the worker's hostname contains "-dev", it will connect to the dev server.
if [[ "$(hostname)" == *"-dev"* ]]; then
    NFS_SERVER_HOSTNAME="jellyfin-server-dev"
    log "INFO: Worker hostname indicates DEV mode. Using NFS server: $NFS_SERVER_HOSTNAME"
else
    NFS_SERVER_HOSTNAME="jellyfin-server"
fi

# Create /etc/fstab dynamically to point to the correct NFS server.
log "INFO: Creating /etc/fstab to mount from $NFS_SERVER_HOSTNAME"
echo "$NFS_SERVER_HOSTNAME:/transcodes /transcodes nfs rw,nolock,actimeo=1 0 0" >> /etc/fstab
echo "$NFS_SERVER_HOSTNAME:/cache /cache nfs rw,nolock,actimeo=1 0 0" >> /etc/fstab

# Attempt to mount file systems from /etc/fstab
if ! mount -a; then
  bail "Failed to mount NFS shares from $NFS_SERVER_HOSTNAME. Check server status and network."
fi
log "INFO: File systems mounted successfully."



log "Starting SSHD..."
# Create the directory for sshd privilege separation
mkdir -p /run/sshd
chmod 700 /run/sshd
# Start the sshd service in the background.
# The -e flag sends logs to stderr, which is useful for container logging.
/usr/sbin/sshd -D -e & 
SSHD_PID=$!
sleep 1 # Give sshd a moment to start
# Check if sshd started successfully
if ! pgrep sshd > /dev/null; then
  bail "SSHD process did not start."
fi
log "SSHD started successfully."

# NFS mount and GPU health are handled by the Docker HEALTHCHECK
# (/healthcheck.sh); swarm replaces the task when it goes unhealthy, with
# start_period grace so a replacement spawned into congestion is not executed
# during startup. The entrypoint only supervises sshd, the process rffmpeg
# actually connects to.
while true; do
  if ! pgrep -x "sshd" >/dev/null; then
    bail "SSHD process is not running. Terminating container."
  fi
  sleep 10 &
  wait $!
done
