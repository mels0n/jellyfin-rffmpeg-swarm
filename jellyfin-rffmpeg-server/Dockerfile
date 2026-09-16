# Fallback for a local `docker build` with no --build-arg; CI always passes the
# resolved upstream version explicitly.
ARG JELLYFIN_VERSION=latest
FROM docker.io/jellyfin/jellyfin:${JELLYFIN_VERSION}

ARG RFFMPEG_URL=https://raw.githubusercontent.com/joshuaboniface/rffmpeg/master/rffmpeg

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8  
ENV LANGUAGE=en_US:en  
ENV LC_ALL=en_US.UTF-8
ENV TMPDIR=/cache/temp 

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

# Installs all system packages, configures rffmpeg, and sets up DVR tools in a single layer.
# This approach is used to minimize the final image size.
RUN apt-get -y update --fix-missing && \
    apt-get install -y --no-install-recommends \
    openssh-client \
    cron \
    python3-click \
    python3-yaml \
    wget \
    git \
    # Comskip build dependencies
    build-essential \
    pkg-config \
    autoconf \
    automake \
    libtool \
    libavformat-dev \
    libargtable2-dev \
    libavutil-dev \
    libavcodec-dev \
    libswscale-dev \
    nfs-common \
    nfs-kernel-server \
    libcap2-bin \
    kmod \
    procps \
    netbase \
    iputils-ping \
    locales \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && \
    locale-gen && \
    # Download the rffmpeg configuration template and customize it for this project's paths and user.
    mkdir -p /tmp/rffmpeg && \
    wget https://raw.githubusercontent.com/joshuaboniface/rffmpeg/master/rffmpeg.yml.sample -O /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#logfile: "/var/log/jellyfin/rffmpeg.log";logfile: "/config/log/rffmpeg.log";' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#datedlogfiles: false;datedlogfiles: true;' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#datedlogdir: "/var/log/jellyfin/";datedlogdir: "/config/log";' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#state: "/var/lib/rffmpeg";state: "/rffmpeg";' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#persist: "/run/shm";persist: "/run";' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#owner: jellyfin;owner: root;' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#group: sudo;group: users;' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#user: jellyfin;user: transcodessh;' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#args:;args:;' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#    - "-i";    - "-i";' /tmp/rffmpeg/rffmpeg.yml && \
    sed -i 's;#    - "/var/lib/jellyfin/id_rsa";    - "/run/rffmpeg/.ssh/id_rsa";' /tmp/rffmpeg/rffmpeg.yml && \    
    # Install comchap/comcut scripts for DVR commercial processing.
    git clone https://github.com/BrettSheleski/comchap.git /tmp/comchap_src && \
    cp /tmp/comchap_src/comchap /usr/local/bin/ && \
    cp /tmp/comchap_src/comcut /usr/local/bin/ && \
    chmod +x /usr/local/bin/comchap /usr/local/bin/comcut && \
    # Create the temporary directory needed for the build process, as defined by ENV TMPDIR.
    mkdir -p /cache/temp && \
    # Build and install comskip from source for maximum compatibility.
    git clone https://github.com/erikkaashoek/Comskip.git /tmp/comskip_src && \
    cd /tmp/comskip_src && \
    ./autogen.sh && \
    ./configure && \
    make && \
    make install && \
    cd / && \
    printf "edl_out=1\noutput_edl=1\noutput_to_stdout=1\nverbose=10\n"  > /etc/comskip.ini && \
    # Removes build-time dependencies (like git) and clears apt caches to reduce image size.
    rm -rf /tmp/comchap_src /tmp/comskip_src && \
    apt-get purge -y --auto-remove wget git build-essential pkg-config autoconf automake && \
    apt-get autoremove -y --purge && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Downloads the rffmpeg binary. 'ADD' is used here because it can handle URLs and
# offers better caching for remote files compared to 'RUN wget'.
ADD ${RFFMPEG_URL} /usr/local/bin/rffmpeg
RUN chmod 755 /usr/local/bin/rffmpeg && \
    ln -sf /usr/local/bin/rffmpeg /usr/local/bin/ffmpeg && \
    ln -sf /usr/local/bin/rffmpeg /usr/local/bin/ffprobe

# Creates the 'transcodessh' user, sets up required directories, and configures permissions.
# This ensures the NFS server and SSH daemon have the correct environment to run in.
RUN \
    (getent group users || groupadd -g 100 users) && \
    useradd -u 7001 -g users -m transcodessh && \
    usermod -a -G video,users,root transcodessh && \
    usermod -a -G users root && \
    mkdir -p /var/lib/nfs/rpc_pipefs /var/lib/nfs/v4recovery && \
    echo "rpc_pipefs  /var/lib/nfs/rpc_pipefs  rpc_pipefs  defaults  0  0" >> /etc/fstab && \
    echo "nfsd        /proc/fs/nfsd            nfsd        defaults  0  0" >> /etc/fstab && \
    mkdir -p /rffmpeg/.ssh /transcodes /cache /cache/temp /config /livetv /home/transcodessh/.ssh && \
    chown -R transcodessh:users /home/transcodessh && \
    chown -R transcodessh:users /rffmpeg/.ssh && \
    chmod 700 /home/transcodessh/.ssh /rffmpeg/.ssh && \
    chgrp users /transcodes /cache /cache/temp /config /livetv && \
    sed -i \
    -e 's;#   IdentityFile ~/.ssh/id_rsa;   IdentityFile /run/rffmpeg/.ssh/id_rsa;' \
    -e 's;#   UserKnownHostsFile ~/.ssh/known_hosts.d/%k;   UserKnownHostsFile /dev/null ;' \
    -e 's;#   StrictHostKeyChecking ask;    StrictHostKeyChecking no;' \
    /etc/ssh/ssh_config

# Copies the container's operational scripts.
# Worker discovery runs as a continuous daemon started by the entrypoint
# (rffmpeg-discovery.sh); cron only handles the nightly rffmpeg state clear.
COPY --chown=root:root rffmpeg-discovery.sh /rffmpeg-discovery.sh
COPY --chown=root:root entrypoint.sh /entrypoint.sh
COPY --chown=root:root recording-post-proceessing.sh /recording-post-processing.sh
RUN chmod +x /rffmpeg-discovery.sh /entrypoint.sh /recording-post-processing.sh && \
    (crontab -l 2>/dev/null; echo "0 0 * * * /usr/local/bin/rffmpeg clear") | crontab -

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

# Record which Jellyfin release this image was built from. Declared here, at the
# very end, so changing it never invalidates the cache for the layers above.
ARG JELLYFIN_VERSION
LABEL org.opencontainers.image.version="${JELLYFIN_VERSION}"

ENTRYPOINT ["/entrypoint.sh"]
