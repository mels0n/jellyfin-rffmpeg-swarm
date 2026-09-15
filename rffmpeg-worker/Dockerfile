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

# Intel compute runtime (OpenCL + Level Zero) for Gen12+ QSV.
#
# INSTALL-OR-SKIP, NEVER DOWNGRADE. These five .debs are one matched release
# train, so they are treated as a bundle: if the base image already carries a
# newer build of any of them, the whole bundle is skipped and the base's stack
# is left exactly as it is. The check runs before any download, so a base that
# is already current costs zero network - this step was the CI's flakiest.
#
# The 24.35.x pin exists because 25.x needs libc6 >= 2.38, which Bookworm does
# not have. A Trixie-based image already ships newer drivers and skips the
# bundle on its own; nothing here needs editing when a base image moves.
ARG IGC_VERSION=1.0.17537.20
ARG NEO_VERSION=24.35.30872.22
ARG GMM_VERSION=22.5.0
ARG LEVEL_ZERO_VERSION=1.3.30872.22
RUN set -eu; \
    skip=""; \
    for pair in "intel-igc-core:${IGC_VERSION}" \
                "intel-igc-opencl:${IGC_VERSION}" \
                "intel-opencl-icd:${NEO_VERSION}" \
                "intel-level-zero-gpu:${LEVEL_ZERO_VERSION}" \
                "libigdgmm12:${GMM_VERSION}"; do \
        pkg="${pair%:*}"; want="${pair##*:}"; \
        have="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"; \
        if [ -n "$have" ] && ! dpkg --compare-versions "$want" gt "$have"; then \
            echo "Intel bundle SKIPPED: $pkg $have is already >= $want"; \
            skip=1; \
        fi; \
    done; \
    if [ -n "$skip" ]; then \
        echo "Base image ships a newer Intel stack - leaving it untouched."; \
        exit 0; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends curl ca-certificates; \
    for url in \
        "https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-core_${IGC_VERSION}_amd64.deb" \
        "https://github.com/intel/intel-graphics-compiler/releases/download/igc-${IGC_VERSION}/intel-igc-opencl_${IGC_VERSION}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-level-zero-gpu_${LEVEL_ZERO_VERSION}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-opencl-icd_${NEO_VERSION}_amd64.deb" \
        "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/libigdgmm12_${GMM_VERSION}_amd64.deb"; \
    do \
        curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -O "$url"; \
    done; \
    apt-get install -y --no-install-recommends ./*.deb; \
    apt-mark manual intel-igc-core intel-igc-opencl intel-level-zero-gpu intel-opencl-icd libigdgmm12; \
    rm -f ./*.deb

# Legacy OpenCL runtime (Gen8-11), extracted to /opt/intel/legacy-opencl.
# Nothing is installed into the system package set here, so this can never
# displace the drivers above. curl is ensured locally because the block above
# no longer guarantees it: it exits early when the bundle is skipped.
WORKDIR /tmp/legacy_neo
RUN set -eu; \
    if ! command -v curl >/dev/null 2>&1; then \
        apt-get update; \
        apt-get install -y --no-install-recommends curl ca-certificates; \
    fi; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -O "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/intel-opencl-icd-legacy1_${NEO_VERSION}_amd64.deb"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 3 -O "https://github.com/intel/compute-runtime/releases/download/${NEO_VERSION}/libigdgmm12_${GMM_VERSION}_amd64.deb"; \
    mkdir -p extracted_icd extracted_gmm /opt/intel/legacy-opencl; \
    dpkg -x "intel-opencl-icd-legacy1_${NEO_VERSION}_amd64.deb" extracted_icd; \
    dpkg -x "libigdgmm12_${GMM_VERSION}_amd64.deb" extracted_gmm; \
    cp "$(find extracted_icd -name 'libigdrcl*.so*' | head -n 1)" /opt/intel/legacy-opencl/libigdrcl_legacy.so; \
    cp "$(find extracted_gmm -name 'libigdgmm*.so*' | head -n 1)" /opt/intel/legacy-opencl/libigdgmm.so.12; \
    rm -rf /tmp/legacy_neo /tmp/neo; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /

COPY entrypoint.sh /entrypoint.sh
COPY healthcheck.sh /healthcheck.sh
RUN chmod +x /entrypoint.sh /healthcheck.sh

# Defaults; the stack file overrides interval/timeout/retries/start_period.
HEALTHCHECK --interval=30s --timeout=15s --retries=3 --start-period=600s \
  CMD ["/healthcheck.sh"]

# The worker tracks jellyfin-ffmpeg7 from the Jellyfin apt repo, not a pinned
# Jellyfin release, so JELLYFIN_VERSION only records which server release this
# image was built to pair with. Kept last so it never busts the build cache.
LABEL org.opencontainers.image.version="${JELLYFIN_VERSION}"

ENTRYPOINT ["/entrypoint.sh"]
