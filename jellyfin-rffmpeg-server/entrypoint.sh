#!/bin/bash

# --- NFS Server Logic ---

# The following NFS server logic is adapted from the entrypoint script of
# the ghcr.io/obeone/nfs-server:latest container image.
# Original project: https://github.com/obeone/docker-nfs-server
readonly ENV_VAR_NFS_DISABLE_VERSION_3='NFS_DISABLE_VERSION_3'
readonly ENV_VAR_NFS_SERVER_THREAD_COUNT='NFS_SERVER_THREAD_COUNT'
readonly ENV_VAR_NFS_ENABLE_KERBEROS='NFS_ENABLE_KERBEROS'
readonly ENV_VAR_NFS_ENABLE_NFSDCLD='NFS_ENABLE_NFSDCLD'
readonly ENV_VAR_NFS_NFSDCLD_STORAGE_DIR='NFS_NFSDCLD_STORAGE_DIR'
readonly ENV_VAR_NFS_PORT_MOUNTD='NFS_PORT_MOUNTD'
readonly ENV_VAR_NFS_PORT='NFS_PORT'
readonly ENV_VAR_NFS_PORT_STATD_IN='NFS_PORT_STATD_IN'
readonly ENV_VAR_NFS_PORT_STATD_OUT='NFS_PORT_STATD_OUT'
readonly ENV_VAR_NFS_VERSION='NFS_VERSION'
readonly ENV_VAR_NFS_EXPORT_PREFIX='NFS_EXPORT_'
readonly ENV_VAR_NFS_LOG_LEVEL='NFS_LOG_LEVEL'

readonly DEFAULT_NFS_PORT=2049
readonly DEFAULT_NFS_PORT_MOUNTD=32767
readonly DEFAULT_NFS_PORT_STATD_IN=32765
readonly DEFAULT_NFS_PORT_STATD_OUT=32766
readonly DEFAULT_NFS_VERSION='4.2'

readonly PATH_BIN_EXPORTFS='/usr/sbin/exportfs'
readonly PATH_BIN_IDMAPD='/usr/sbin/rpc.idmapd'
readonly PATH_BIN_MOUNTD='/usr/sbin/rpc.mountd'
readonly PATH_BIN_NFSD='/usr/sbin/rpc.nfsd'
readonly PATH_BIN_RPCBIND='/sbin/rpcbind'
readonly PATH_BIN_STATD='/sbin/rpc.statd'

readonly PATH_BIN_RPC_SVCGSSD='/usr/sbin/rpc.svcgssd'
readonly PATH_BIN_NFSDCLD='/usr/sbin/nfsdcld'

readonly PATH_FILE_ETC_EXPORTS='/etc/exports'
readonly PATH_FILE_ETC_IDMAPD_CONF='/etc/idmapd.conf'
readonly PATH_FILE_ETC_KRB5_CONF='/etc/krb5.conf'
readonly PATH_FILE_ETC_KRB5_KEYTAB='/etc/krb5.keytab'

readonly MOUNT_PATH_NFSD='/proc/fs/nfsd'
readonly MOUNT_PATH_RPC_PIPEFS='/var/lib/nfs/rpc_pipefs'

readonly REGEX_EXPORTS_LINES_TO_SKIP='^\s*#|^\s*$'
readonly LOG_LEVEL_INFO='INFO'
readonly LOG_LEVEL_DEBUG='DEBUG'

readonly STATE_LOG_LEVEL='log_level'
readonly STATE_IS_LOGGING_DEBUG='is_logging_debug'
readonly STATE_IS_LOGGING_INFO='is_logging_info'
readonly STATE_NFSD_THREAD_COUNT='nfsd_thread_count'
readonly STATE_NFSD_PORT='nfsd_port'
readonly STATE_MOUNTD_PORT='mountd_port'
readonly STATE_STATD_PORT_IN='statd_port_in'
readonly STATE_STATD_PORT_OUT='statd_port_out'
readonly STATE_NFS_VERSION='nfs_version'
readonly STATE_NFSDCLD_STORAGE_DIR='nfsdcld_storage_dir'

declare -A state

log() {
  echo "-----> $1"
}

log_warning() {
  log "WARNING: $1"
}

log_error() {
  log ''
  log "ERROR: $1"
  log ''
}

log_header() {
  echo "
==================================================================
      ${1^^}
=================================================================="
}

bail() {
  log_error "$1"
  exit 1
}

on_failure() {
  # shellcheck disable=SC2181
  if [[ $? -eq 0 ]]; then
    return
  fi 

  case "$1" in
    warn)
      log_warning "$2"
      ;;
    stop)
      log_error "$2"
      nfs_stop
      exit 1
      ;;
    *)
      bail "$2"
      ;;
  esac
}

term_process() {
  local -r base=$(basename "$1")
  local -r pid=$(pidof "$base")

  if [[ -n $pid ]]; then
    log "terminating $base"
    kill "$pid"
    on_failure warn "unable to terminate $base"
  else
    log "$base was not running"
  fi
}

stop_mount() {
  local -r path=$1
  local -r type=$(basename "$path")

  if mount | grep -Eq "^$type on $path\\s+"; then
    local args=()
    if [[ -n ${nfs_state[is_logging_debug]} ]]; then
      args+=('-v')
      log "un-mounting $type filesystem from $path"
    fi
    args+=("$path")
    umount "${args[@]}"
    on_failure warn "unable to un-mount $type filesystem from $path"
  fi
}

stop_nfsd() {
  log 'terminating nfsd'
  $PATH_BIN_NFSD 0
  on_failure warn 'unable to terminate nfsd'
}

stop_exportfs() {
  local args=('-ua')
  if [[ -n ${nfs_state[is_logging_debug]} ]]; then
    args+=('-v')
  fi
  log 'un-exporting filesystem(s)'
  $PATH_BIN_EXPORTFS "${args[@]}"
  on_failure warn 'unable to un-export filesystem(s)'
}

nfs_stop() {
  log_header 'terminating ...'

  if is_kerberos_requested; then
    term_process "$PATH_BIN_RPC_SVCGSSD"
  fi

  stop_nfsd
  term_process "$PATH_BIN_IDMAPD"
  term_process "$PATH_BIN_STATD"
  term_process "$PATH_BIN_MOUNTD"
  stop_exportfs
  term_process "$PATH_BIN_RPCBIND"
  stop_mount "$MOUNT_PATH_NFSD"
  stop_mount "$MOUNT_PATH_RPC_PIPEFS"
  log_header 'nfs services terminated'
}

is_kerberos_requested() {
  [[ -n "${!ENV_VAR_NFS_ENABLE_KERBEROS}" ]] && return 0 || return 1
}

is_nfsdcld_requested() {
  [[ -n "${!ENV_VAR_NFS_ENABLE_NFSDCLD}" ]] && return 0 || return 1
}

is_nfs3_enabled() {
  [[ -z "${!ENV_VAR_NFS_DISABLE_VERSION_3}" ]] && return 0 || return 1
}

is_idmapd_requested() {
  [[ -f "$PATH_FILE_ETC_IDMAPD_CONF" ]] && return 0 || return 1
}

is_logging_debug() {
  [[ -n ${state[$STATE_IS_LOGGING_DEBUG]} ]] && return 0 || return 1
}

is_granted_linux_capability() {
  if capsh --decode=$(grep CapBnd /proc/$$/status|cut -f2) | grep cap_sys_admin &> /dev/null; then
    return 0
  fi
  return 1
}

init_state_logging() {
  local incoming_log_level="${!ENV_VAR_NFS_LOG_LEVEL:-$LOG_LEVEL_INFO}"
  local -r normalized_log_level="${incoming_log_level^^}"

  if ! echo "$normalized_log_level" | grep -Eq 'DEBUG|INFO'; then
    bail "the only acceptable values for $ENV_VAR_NFS_LOG_LEVEL are: DEBUG, INFO"
  fi

  state[$STATE_LOG_LEVEL]=$normalized_log_level;
  state[$STATE_IS_LOGGING_INFO]=1

  if [[ $normalized_log_level = "$LOG_LEVEL_DEBUG" ]]; then
    state[$STATE_IS_LOGGING_DEBUG]=1
    log "nfs log level set to $LOG_LEVEL_DEBUG"
  fi
}

init_state_nfsd_thread_count() {
  local count
  if [[ -n "${!ENV_VAR_NFS_SERVER_THREAD_COUNT}" ]]; then
    count="${!ENV_VAR_NFS_SERVER_THREAD_COUNT}"
    if [[ $count -lt 1 ]]; then
      bail "please set $ENV_VAR_NFS_SERVER_THREAD_COUNT to a positive integer"
    fi
    if is_logging_debug; then
      log "will use requested rpc.nfsd thread count of $count"
    fi
  else
    count="$(grep -Ec ^processor /proc/cpuinfo)"
    on_failure bail "unable to detect CPU count. set $ENV_VAR_NFS_SERVER_THREAD_COUNT environment variable"
    if is_logging_debug; then
      log "will use $count rpc.nfsd server thread(s) (1 thread per CPU)"
    fi
  fi
  state[$STATE_NFSD_THREAD_COUNT]=$count
}

init_exports() {
    # Disable globbing to prevent shell expansion of characters like '*' in export options.
    set -o noglob

    local count_valid_exports=0
    local exports=''
    local candidate_export_vars

    # collect all candidate environment variable names
    mapfile -t candidate_export_vars < <(compgen -A variable | grep -E "${ENV_VAR_NFS_EXPORT_PREFIX}[0-9]+" | sort)
    on_failure bail "failed to detect ${ENV_VAR_NFS_EXPORT_PREFIX}* variables"

    if [[ ${#candidate_export_vars[@]} -eq 0 ]]; then
      bail "please set at least one ${ENV_VAR_NFS_EXPORT_PREFIX}* environment variable"
    fi

    log "building $PATH_FILE_ETC_EXPORTS from environment variables"

    # iterate over all candidate environment variables
    for candidate_export_var in "${candidate_export_vars[@]}"; do
      local line="${!candidate_export_var}"
      if [[ "$line" =~ $REGEX_EXPORTS_LINES_TO_SKIP ]]; then
        continue;
      fi
      local line_as_array
      read -r -a line_as_array <<< "$line"
      local dir="${line_as_array[0]}"

      # make sure the directory to be exported exists
      if [[ -z "$dir" || ! -d "$dir" ]]; then
        log_warning "skipping export: Directory '$dir' defined in '$candidate_export_var' does not exist."
        continue
      else
        log "validating export: '$dir' (ownership: $(stat -c '%U:%G' "$dir"), perms: $(stat -c '%a' "$dir"))"
      fi
      if [[ $count_valid_exports -gt 0 ]]; then
        exports=$exports$'\n'
      fi
      exports=$exports$line
      (( count_valid_exports++ ))
    done

    if [[ $count_valid_exports -eq 0 ]]; then
      bail 'no valid exports'
    fi

    echo "$exports" > $PATH_FILE_ETC_EXPORTS
    on_failure bail "unable to write to $PATH_FILE_ETC_EXPORTS"

    # Re-enable globbing.
    set +o noglob
}

assert_kernel_mod() {
  local -r module=$1
  if lsmod | grep -Eq "^$module\\s+"; then
    return
  fi
  log "attempting to load kernel module $module"
  modprobe -v "$module"
  on_failure bail "unable to dynamically load kernel module $module. try modprobe $module on the Docker host"
}

init_runtime_assertions() {
  if ! is_granted_linux_capability 'cap_sys_admin'; then
    bail 'missing CAP_SYS_ADMIN. be sure to run this image with --cap-add SYS_ADMIN or --privileged'
  fi
  assert_kernel_mod nfs
  assert_kernel_mod nfsd
}

boot_helper_get_version_flags() {
  local -r requested_version="${state[$STATE_NFS_VERSION]:-$DEFAULT_NFS_VERSION}"
  local flags=('--nfs-version' "$requested_version")

  if ! is_nfs3_enabled; then
    flags+=('--no-nfs-version' 3)
  fi

  if [[ "$requested_version" = '3' ]]; then
    flags+=('--no-nfs-version' 4)
  fi

  echo "${flags[@]}"
}

boot_helper_start_non_daemon() {
  local -r msg="$1"; shift
  log "$msg"; "$@" &
  sleep .001; kill -0 $! 2> /dev/null
  on_failure stop "$1 failed"
}

boot_helper_mount() {
  local -r path=$1
  local -r type=$(basename "$path")
  local args=('-t' "$type" "$path")
  if [[ -n ${nfs_state[is_logging_debug]} ]]; then
    args+=('-vvv')
    log "mounting $type filesystem onto $path"
  fi
  mount "${args[@]}"
  on_failure stop "unable to mount $type filesystem onto $path"
}

boot_helper_start_daemon() {
  local -r msg="$1"
  local -r daemon="$2"
  shift 2
  local -r daemon_args=("$@")
  log "$msg"
  "$daemon" "${daemon_args[@]}"
  on_failure stop "$daemon failed"
}

boot_main_mounts() {
  boot_helper_mount "$MOUNT_PATH_RPC_PIPEFS"
  boot_helper_mount "$MOUNT_PATH_NFSD"
}

boot_main_exportfs() {
  local args=('-ar')
  if is_logging_debug; then
    args+=('-v')
  fi
  boot_helper_start_daemon 'starting exportfs' $PATH_BIN_EXPORTFS "${args[@]}"
}

boot_main_mountd() {
  local args=()
  read -r -a version_flags <<< "$(boot_helper_get_version_flags)"
  local -r port="${state[$STATE_MOUNTD_PORT]:-$DEFAULT_NFS_PORT_MOUNTD}"
  args=('--port' "$port" "${version_flags[@]}")
  if is_logging_debug; then
    args+=('--debug' 'all')
  fi
  boot_helper_start_daemon "starting rpc.mountd on port $port" $PATH_BIN_MOUNTD "${args[@]}"
}

boot_main_rpcbind() {
  local args=('-w' '-s')
  if is_logging_debug; then
    args+=('-d')
  fi
  boot_helper_start_daemon 'starting rpcbind' $PATH_BIN_RPCBIND "${args[@]}"
}

boot_main_idmapd() {
  if ! is_idmapd_requested; then
    return
  fi
  local args=('-S')
  local func=boot_helper_start_daemon
  if is_logging_debug; then
    args+=('-vvv' '-f')
    func=boot_helper_start_non_daemon
  fi
  $func 'starting rpc.idmapd' $PATH_BIN_IDMAPD "${args[@]}"
}

boot_main_statd() {
  if ! is_nfs3_enabled; then
    return
  fi
  local -r port_in="${state[$STATE_STATD_PORT_IN]:-$DEFAULT_NFS_PORT_STATD_IN}"
  local -r port_out="${state[$STATE_STATD_PORT_OUT]:-$DEFAULT_NFS_PORT_STATD_OUT}"
  local args=('--no-notify' '--port' "$port_in" '--outgoing-port' "$port_out")
  local func=boot_helper_start_daemon
  if is_logging_debug; then
    args+=('--no-syslog' '--foreground')
    func=boot_helper_start_non_daemon
  fi
  $func "starting rpc.statd on port $port_in (outgoing from port $port_out)" $PATH_BIN_STATD "${args[@]}"
}

boot_main_nfsd() {
  local version_flags
  read -r -a version_flags <<< "$(boot_helper_get_version_flags)"
  local -r threads="${state[$STATE_NFSD_THREAD_COUNT]}"
  local -r port="${state[$STATE_NFSD_PORT]:-$DEFAULT_NFS_PORT}"
  local args=('--tcp' '--udp' '--port' "$port" "${version_flags[@]}" "$threads")
  if is_logging_debug; then
    args+=('--debug')
  fi
  boot_helper_start_daemon "starting rpc.nfsd on port $port with $threads server thread(s)" $PATH_BIN_NFSD "${args[@]}"
  if ! is_nfs3_enabled; then
    term_process "$PATH_BIN_RPCBIND"
  fi
}

init() {
  log_header 'setting up nfs services...'
  init_state_logging
  init_state_nfsd_thread_count
  init_exports
  init_runtime_assertions
  trap '
    nfs_stop
  ' SIGTERM SIGINT
  log 'nfs setup complete'
}

boot() {
  log_header 'starting nfs services ...'
  boot_main_mounts
  boot_main_rpcbind
  boot_main_exportfs
  boot_main_mountd
  boot_main_statd
  boot_main_idmapd
  boot_main_nfsd
  log 'all nfs services started normally'
}

main() {
  init
  boot
  log_header 'nfs server startup complete'
}

# --- OpenCL Verification ---
export LD_LIBRARY_PATH="/opt/intel/legacy-opencl:$LD_LIBRARY_PATH"
log_header 'Checking OpenCL Status'
if command -v clinfo > /dev/null; then
    clinfo | grep "Platform Name" || echo "No OpenCL platforms found."
else
    log_warning "clinfo not found."
fi
log_header 'OpenCL Check Complete'

main

# --- Jellyfin Logic ---
# Start cron in the background
service cron start

# Add transcodessh user to the GPU's render group for hardware acceleration access.
if [ -e "/dev/dri/renderD128" ]; then
    renderD128_gid=$(stat -c "%g" /dev/dri/renderD128)
    if ! getent group "$renderD128_gid" > /dev/null 2>&1; then
        groupadd --gid "$renderD128_gid" render
    fi
    usermod -a -G "$renderD128_gid" transcodessh
fi

# Set umask to ensure new files are group-writable, which is crucial for rffmpeg workers.
# This can be overridden by setting the UMASK environment variable.
umask "${UMASK:-002}" 

# rffmpeg setup ------
# Copy SSH keys from Docker secrets to a runtime-only path.
if [ -f /run/secrets/rffmpeg_id_rsa ] && [ -f /run/secrets/rffmpeg_id_rsa_pub ]; then
  echo "INFO: Setting up SSH keys from secrets into runtime /run/rffmpeg/.ssh"
  mkdir -p /run/rffmpeg/.ssh
  cp /run/secrets/rffmpeg_id_rsa /run/rffmpeg/.ssh/id_rsa
  cp /run/secrets/rffmpeg_id_rsa_pub /run/rffmpeg/.ssh/id_rsa.pub
  # keep a copy of the public key (not sensitive) for convenience
  cp /run/secrets/rffmpeg_id_rsa_pub /run/rffmpeg/.ssh/authorized_keys

  # Set ownership and permissions required by sshd.
  chown -R transcodessh:users /run/rffmpeg/.ssh
  chmod 700 /run/rffmpeg/.ssh
  chmod 600 /run/rffmpeg/.ssh/id_rsa
  chmod 644 /run/rffmpeg/.ssh/id_rsa.pub /run/rffmpeg/.ssh/authorized_keys
fi

# Ensure the /rffmpeg directory exists
mkdir -p /rffmpeg
# Copy rffmpeg.yml from the temporary location to the volume if it doesn't exist
if [ ! -f /rffmpeg/rffmpeg.yml ]; then
    cp /tmp/rffmpeg/rffmpeg.yml /rffmpeg/rffmpeg.yml
fi
# Ensure the /etc/rffmpeg directory exists
mkdir -p /etc/rffmpeg
# Link config volume location to runtime location for rffmpeg
ln -s /rffmpeg/rffmpeg.yml /etc/rffmpeg/rffmpeg.yml

# Initialize the rffmpeg database on first run, or clear it on subsequent runs.
if [ ! -f /rffmpeg/rffmpeg.db ]; then
    /usr/local/bin/rffmpeg init -y
else
    /usr/local/bin/rffmpeg clear
fi

# Start the continuous worker discovery daemon. Started here (not cron) so
# workers are registered within seconds of container start: the rffmpeg DB
# is ephemeral, and without this every server restart would begin with an
# empty host list and transcode locally until discovery caught up.
/rffmpeg-discovery.sh &
echo "INFO: Worker discovery daemon started (PID $!)"
#------

# Create default Live TV configuration if it doesn't exist.
# This is done in the entrypoint so it can write to the /config volume after it's mounted.
# It checks for the file's existence to avoid overwriting user changes on subsequent runs.
CONFIG_DIR="/config/config"
LIVETV_CONFIG_FILE="$CONFIG_DIR/livetv.xml"
if [ ! -f "$LIVETV_CONFIG_FILE" ]; then
    echo "INFO: Live TV config not found. Creating default at $LIVETV_CONFIG_FILE"
    mkdir -p "$CONFIG_DIR"
    cat > "$LIVETV_CONFIG_FILE" << EOF
<LiveTvOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <RecordingPath>/livetv</RecordingPath>
  <EnableRecordingSubfolders>false</EnableRecordingSubfolders>
  <EnableOriginalAudioWithEncodedRecordings>false</EnableOriginalAudioWithEncodedRecordings>
  <RecordingPostProcessor>/recording-post-processing.sh</RecordingPostProcessor>
  <RecordingPostProcessorArguments>"{path}"</RecordingPostProcessorArguments>
</LiveTvOptions>
EOF
else
    echo "INFO: Existing Live TV config found. Skipping creation."
fi

# Create default Encoding configuration if it doesn't exist.
ENCODING_CONFIG_FILE="$CONFIG_DIR/encoding.xml"
if [ ! -f "$ENCODING_CONFIG_FILE" ]; then
    echo "INFO: Encoding config not found. Creating default at $ENCODING_CONFIG_FILE"
    mkdir -p "$CONFIG_DIR"
    cat > "$ENCODING_CONFIG_FILE" << EOF
<?xml version="1.0" encoding="utf-8"?>
<EncodingOptions xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
  <TranscodingTempPath>/transcodes</TranscodingTempPath>
  <EnableThrottling>true</EnableThrottling>
  <ThrottleDelaySeconds>180</ThrottleDelaySeconds>
  <EnableSegmentDeletion>true</EnableSegmentDeletion>
  <SegmentKeepSeconds>720</SegmentKeepSeconds>
  <HardwareAccelerationType>qsv</HardwareAccelerationType>
  <EncoderAppPathDisplay>/usr/local/bin/ffmpeg</EncoderAppPathDisplay>
  <EnableEnhancedNvdecDecoder>true</EnableEnhancedNvdecDecoder>
  <PreferSystemNativeHwDecoder>true</PreferSystemNativeHwDecoder>
  <EnableIntelLowPowerH264HwEncoder>true</EnableIntelLowPowerH264HwEncoder>
  <EnableIntelLowPowerHevcHwEncoder>false</EnableIntelLowPowerHevcHwEncoder>
  <EnableHardwareEncoding>true</EnableHardwareEncoding>
</EncodingOptions>
EOF
else
    echo "INFO: Existing Encoding config found. Skipping creation."
fi

# Set a umask to ensure all files created by Jellyfin and its children (like ffmpeg) are group-writable.
umask 002

# Start Jellyfin
/jellyfin/jellyfin --datadir /config --cachedir /cache --ffmpeg /usr/local/bin/ffmpeg &
# Wait for the Jellyfin process to terminate.
wait $!
