FROM debian:bookworm

ARG JELLYFIN_VERSION=10.10.7

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get -y install --no-install-recommends curl gnupg locales openssh-server nfs-common netbase iputils-ping fontconfig ca-certificates && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    # Add jellyfin repo using the modern signed-by method
    mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://repo.jellyfin.org/jellyfin_team.gpg.key | gpg --dearmor -o /etc/apt/keyrings/jellyfin.gpg && \
    echo "deb [arch=$( dpkg --print-architecture ) signed-by=/etc/apt/keyrings/jellyfin.gpg] https://repo.jellyfin.org/debian bookworm main" > /etc/apt/sources.list.d/jellyfin.list && \
    # Install jellyfin-ffmpeg7 from the new repo and clean up
    apt-get update && \ 
    apt-get install -y --no-install-recommends jellyfin-ffmpeg7 && \ 
    apt-get purge -y --auto-remove gnupg curl && \ 
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8  
ENV LANGUAGE=en_US:en  
ENV LC_ALL=en_US.UTF-8

# ==============================================================================
# OpenCL Support (Current & Legacy)
# ==============================================================================

# 1. Install Prerequisites
RUN apt-get update && apt-get install -y \
    wget \
    gnupg2 \
    clinfo \
    binutils \
    libnuma1 \
    ocl-icd-libopencl1 \
    && rm -rf /var/lib/apt/lists/*

# ==============================================================================
# PHASE 3: Configuration & Binding
# ==============================================================================

# 1. Register the Legacy Driver with the OpenCL Loader
# The loader scans /etc/OpenCL/vendors/*.icd. 
# We point it to our renamed legacy library.
RUN mkdir -p /etc/OpenCL/vendors && \
    echo "/opt/intel/legacy-opencl/libigdrcl_legacy.so" > /etc/OpenCL/vendors/intel_legacy.icd

# 2. Setup Environment Variables
# We must add the legacy folder to LD_LIBRARY_PATH so the legacy driver can find its specific GMM library.
ENV LD_LIBRARY_PATH="/opt/intel/legacy-opencl"

# Create directories, set permissions, and define NFS mounts for the entrypoint.
RUN (getent group users || groupadd -g 100 users) && \
    mkdir -p /transcodes /cache /config /livetv && \
    chgrp users /transcodes /cache /config /livetv

# Create the transcodessh user for receiving jobs.
RUN useradd -u 7001 -g users -m transcodessh && \
    usermod --shell /bin/bash transcodessh && \
    usermod -aG video,users transcodessh

# Set a global umask to ensure group-writable files.
RUN echo 'umask 002' >> /etc/profile

EXPOSE 22

# ==============================================================================
# PHASE 4: Install Drivers (Moved to end to avoid autoremove)
# ==============================================================================
WORKDIR /tmp/neo

# Install Current Drivers (Gen12+)
# We use 24.35.30872.22 because newer versions (25.x) require libc6 >= 2.38, which is not available in Debian Bookworm.
RUN apt-get update && apt-get install -y curl && \
    curl -L -O https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-core_1.0.17537.20_amd64.deb && \
    curl -L -O https://github.com/intel/intel-graphics-compiler/releases/download/igc-1.0.17537.20/intel-igc-opencl_1.0.17537.20_amd64.deb && \
    curl -L -O https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-level-zero-gpu_1.3.30872.22_amd64.deb && \
    curl -L -O https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-opencl-icd_24.35.30872.22_amd64.deb && \
    curl -L -O https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/libigdgmm12_22.5.0_amd64.deb && \
    apt-get install -y --allow-downgrades ./*.deb && \
    apt-mark manual intel-igc-core intel-igc-opencl intel-level-zero-gpu intel-opencl-icd libigdgmm12 && \
    rm *.deb

# Install Legacy Drivers (Gen8-11)
WORKDIR /tmp/legacy_neo
RUN curl -L -O https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb && \
    curl -L -O https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/libigdgmm12_22.5.0_amd64.deb && \
    mkdir -p extracted_icd && dpkg -x intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb extracted_icd && \
    mkdir -p extracted_gmm && dpkg -x libigdgmm12_22.5.0_amd64.deb extracted_gmm && \
    mkdir -p /opt/intel/legacy-opencl && \
    cp $(find extracted_icd -name "libigdrcl*.so*" | head -n 1) /opt/intel/legacy-opencl/libigdrcl_legacy.so && \
    cp $(find extracted_gmm -name "libigdgmm*.so*" | head -n 1) /opt/intel/legacy-opencl/libigdgmm.so.12 && \
    rm -rf /tmp/legacy_neo /tmp/neo

WORKDIR /

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

# Defaults; the stack file overrides interval/timeout/retries/start_period.
HEALTHCHECK --interval=30s --timeout=15s --retries=3 --start-period=600s \
  CMD ["/healthcheck.sh"]

ENTRYPOINT ["/entrypoint.sh"]
