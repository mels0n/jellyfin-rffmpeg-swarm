# Manual Node Setup

Configure a Swarm node by hand. These are the same steps `setup-node.sh` performs, in the
same order, so this doubles as a reference for what that script does to a host.

**Perform these steps on ALL nodes in your Swarm cluster.**

> **Ubuntu vs Debian.** `setup-node.sh` installs current Intel drivers from Intel's own
> apt repository, which it builds as `repositories.intel.com/gpu/ubuntu <codename>` - an
> Ubuntu path. On Debian, skip step 4.1's repository and use the distro's own
> `intel-opencl-icd`: Debian Trixie ships a current compute runtime, so no side-loading is
> needed for Gen12+.

## 1. Install system dependencies

```bash
sudo apt update
sudo apt install -y nfs-common nfs-kernel-server intel-opencl-icd clinfo binutils ocl-icd-libopencl1 wget gnupg2 ca-certificates libnuma1
```

## 2. Configure kernel modules

```bash
sudo sh -c "echo 'nfsd' >> /etc/modules"
sudo sh -c "echo 'nfs' >> /etc/modules"
sudo modprobe nfsd nfs
```

## 3. Create host directories

The `jellyfin-server` container exports these over NFS. GID 100 (`users`) is what the
server writes as.

```bash
sudo mkdir -p /transcodes /cache
sudo chgrp users /transcodes /cache
sudo chmod 775 /transcodes /cache
```

## 4. OpenCL drivers (current and legacy, side by side)

Current drivers (Gen12+) are installed as system packages. Legacy drivers (Gen8-11) are
extracted to `/opt/intel/legacy-opencl` instead of installed, so the two never conflict.

### 4.1 Current drivers (Gen12+)

Add Intel's apt repository and install from it, so the packages match the running OS and
keep updating with it:

```bash
sudo mkdir -p /etc/apt/keyrings
wget -qO - https://repositories.intel.com/gpu/intel-graphics.key \
  | sudo gpg --dearmor --yes -o /etc/apt/keyrings/intel-graphics.gpg
echo "deb [arch=amd64,i386 signed-by=/etc/apt/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ubuntu $(lsb_release -cs) client" \
  | sudo tee /etc/apt/sources.list.d/intel-gpu-$(lsb_release -cs).list

sudo apt update
sudo apt install -y intel-opencl-icd intel-level-zero-gpu level-zero
```

Do not replace these with hand-picked `.deb` files from the compute-runtime releases page
unless you have checked that they are *newer* than what is installed. Pinned downloads go
stale and quietly downgrade a working driver stack - the mistake this project made inside
its own images, recorded in
[ADR-0004](../adr/0004-intel-driver-install-or-skip.md).

### 4.2 Legacy drivers (Gen8-11)

```bash
mkdir -p /tmp/neo_legacy && cd /tmp/neo_legacy

wget https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb
wget https://github.com/intel/compute-runtime/releases/download/24.35.30872.22/libigdgmm12_22.5.0_amd64.deb

mkdir -p extracted_icd extracted_gmm
dpkg -x intel-opencl-icd-legacy1_24.35.30872.22_amd64.deb extracted_icd
dpkg -x libigdgmm12_22.5.0_amd64.deb extracted_gmm

sudo mkdir -p /opt/intel/legacy-opencl
sudo cp "$(find extracted_icd -name 'libigdrcl*.so*' | head -n 1)" /opt/intel/legacy-opencl/libigdrcl_legacy.so
sudo cp "$(find extracted_gmm -name 'libigdgmm*.so*' | head -n 1)" /opt/intel/legacy-opencl/libigdgmm.so.12

cd / && rm -rf /tmp/neo_legacy
```

These are extracted, not installed, so they cannot displace the current drivers above.

### 4.3 Register the legacy driver with the OpenCL loader

```bash
sudo sh -c 'echo "/opt/intel/legacy-opencl/libigdrcl_legacy.so" > /etc/OpenCL/vendors/intel_legacy.icd'
```

### 4.4 Put the legacy driver on the library path

```bash
sudo sh -c 'echo "export LD_LIBRARY_PATH=/opt/intel/legacy-opencl:\$LD_LIBRARY_PATH" > /etc/profile.d/intel-opencl.sh'
sudo chmod 644 /etc/profile.d/intel-opencl.sh
```

Check the result with `clinfo -l`.

## 5. Disable AppArmor (required)

AppArmor prevents the `jellyfin-server` container from acquiring the permissions its NFS
server needs. This is a real security concession; it is what
[ADR-0002](../adr/0002-embedded-nfs-server.md) trades away.

```bash
sudo systemctl stop apparmor && sudo systemctl disable apparmor
sudo apt purge -y apparmor
# Add 'apparmor=0' to the kernel boot parameters
sudo sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 apparmor=0"/' /etc/default/grub
sudo update-grub
```

**A reboot is required** for the kernel parameter to take effect. Confirm afterwards with
`grep apparmor=0 /proc/cmdline`.

## 6. Add your user to the render and video groups

Needed to use `/dev/dri` without root, e.g. to run `clinfo` or `vainfo` as yourself.

```bash
sudo usermod -aG render "$USER"
sudo usermod -aG video "$USER"
```

Log out and back in, or run `newgrp render`, for this to take effect.
