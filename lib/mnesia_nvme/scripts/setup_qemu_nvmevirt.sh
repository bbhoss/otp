#!/bin/bash
#
# Setup script for testing Mnesia NVMe backend with NVMeVirt in QEMU
#
# This script creates a QEMU VM that can load the NVMeVirt kernel module
# with KV (Key-Value) SSD emulation enabled.
#
# Requirements:
# - QEMU with NVMe support
# - A Linux kernel image and initrd
# - Root/sudo access for VM setup
#
# Usage: ./setup_qemu_nvmevirt.sh [options]
#   --mem SIZE     Memory size (default: 4G)
#   --cpus NUM     Number of CPUs (default: 4)
#   --nvme-size    NVMe backing file size (default: 1G)
#

set -e

# Default configuration
MEM_SIZE="4G"
CPUS=4
NVME_SIZE="1G"
WORK_DIR="${HOME}/nvmevirt-test"
KERNEL_VERSION=$(uname -r)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --mem)
            MEM_SIZE="$2"
            shift 2
            ;;
        --cpus)
            CPUS="$2"
            shift 2
            ;;
        --nvme-size)
            NVME_SIZE="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--mem SIZE] [--cpus NUM] [--nvme-size SIZE]"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=== NVMeVirt QEMU Test Environment Setup ==="
echo "Memory: ${MEM_SIZE}"
echo "CPUs: ${CPUS}"
echo "NVMe Size: ${NVME_SIZE}"
echo "Work Dir: ${WORK_DIR}"
echo ""

# Create work directory
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# Create a disk image for the root filesystem if it doesn't exist
if [[ ! -f rootfs.qcow2 ]]; then
    echo "Creating root filesystem image..."
    qemu-img create -f qcow2 rootfs.qcow2 20G
fi

# Create NVMe backing file
if [[ ! -f nvme_backend.img ]]; then
    echo "Creating NVMe backing file..."
    qemu-img create -f raw nvme_backend.img ${NVME_SIZE}
fi

# Create a cloud-init config for automated setup
mkdir -p cloud-init
cat > cloud-init/user-data <<'EOF'
#cloud-config
users:
  - name: nvmetest
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys: []

packages:
  - build-essential
  - linux-headers-generic
  - git
  - erlang
  - nvme-cli

runcmd:
  - |
    # Clone and build NVMeVirt
    cd /home/nvmetest
    git clone https://github.com/snu-csl/nvmevirt.git
    cd nvmevirt

    # Configure for KV mode
    sed -i 's/^CONFIG_NVMEVIRT_NVM := y/#CONFIG_NVMEVIRT_NVM := y/' Kbuild
    sed -i 's/^#CONFIG_NVMEVIRT_KV := y/CONFIG_NVMEVIRT_KV := y/' Kbuild

    # Build the module
    make

    echo "NVMeVirt KV module built. Load with:"
    echo "  sudo insmod nvmev.ko memmap_start=1G memmap_size=512M cpus=2,3"
EOF

cat > cloud-init/meta-data <<EOF
instance-id: nvmevirt-test
local-hostname: nvmevirt-test
EOF

# Create cloud-init ISO
echo "Creating cloud-init ISO..."
if command -v genisoimage &> /dev/null; then
    genisoimage -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data 2>/dev/null || true
elif command -v mkisofs &> /dev/null; then
    mkisofs -output cloud-init.iso -volid cidata -joliet -rock cloud-init/user-data cloud-init/meta-data 2>/dev/null || true
else
    echo "Warning: No ISO creation tool available (genisoimage or mkisofs)"
fi

# Create QEMU launch script
cat > run_qemu.sh <<EOF
#!/bin/bash
#
# Launch QEMU with NVMeVirt-ready configuration
#
# This script configures QEMU with:
# - Memory reservation for NVMeVirt (via memmap kernel parameter)
# - CPU isolation for NVMeVirt (via isolcpus kernel parameter)
# - NVMe device for storage
#

QEMU_CMD="qemu-system-x86_64"

# Check for KVM support
if [[ -w /dev/kvm ]]; then
    QEMU_CMD="\${QEMU_CMD} -enable-kvm"
    echo "KVM acceleration enabled"
else
    echo "Warning: KVM not available, using TCG (slower)"
fi

\${QEMU_CMD} \\
    -m ${MEM_SIZE} \\
    -smp ${CPUS} \\
    -cpu host \\
    -drive file=rootfs.qcow2,if=virtio,format=qcow2 \\
    -drive file=cloud-init.iso,if=virtio,format=raw \\
    -netdev user,id=net0,hostfwd=tcp::2222-:22 \\
    -device virtio-net-pci,netdev=net0 \\
    -nographic \\
    -append "console=ttyS0 memmap=512M\\\$1G isolcpus=2,3"

# Note: After booting, you can SSH into the VM:
# ssh -p 2222 nvmetest@localhost
#
# Then load NVMeVirt:
# cd /home/nvmetest/nvmevirt
# sudo insmod nvmev.ko memmap_start=1G memmap_size=512M cpus=2,3
#
# The device will appear as /dev/nvme0 and /dev/ng0n1
EOF

chmod +x run_qemu.sh

# Create a minimal test script
cat > test_nvme_kv.sh <<'EOF'
#!/bin/bash
#
# Test NVMe KV operations using nvme-cli
# Run this inside the QEMU VM after loading NVMeVirt
#

DEVICE="/dev/ng0n1"
NSID=1

echo "Testing NVMe KV operations on ${DEVICE}"

# Check if device exists
if [[ ! -e "${DEVICE}" ]]; then
    echo "Error: Device ${DEVICE} not found"
    echo "Make sure NVMeVirt is loaded with KV mode"
    exit 1
fi

# Note: Standard nvme-cli doesn't support KV commands directly
# You would need the KVSSD-specific tools or custom implementation
echo "Device found. For KV operations, use the Erlang mnesia_nvme module."
echo ""
echo "Example Erlang session:"
echo "  1> {ok, H} = mnesia_nvme_device:open(\"${DEVICE}\")."
echo "  2> mnesia_nvme_device:store(H, ${NSID}, <<\"mykey\">>, <<\"myvalue\">>)."
echo "  3> mnesia_nvme_device:retrieve(H, ${NSID}, <<\"mykey\">>)."

EOF

chmod +x test_nvme_kv.sh

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Files created in ${WORK_DIR}:"
echo "  - rootfs.qcow2      : Root filesystem image (needs OS installation)"
echo "  - nvme_backend.img  : NVMe backing storage"
echo "  - cloud-init.iso    : Cloud-init configuration"
echo "  - run_qemu.sh       : QEMU launch script"
echo "  - test_nvme_kv.sh   : NVMe KV test script"
echo ""
echo "Next steps:"
echo "  1. Install a Linux distribution to rootfs.qcow2"
echo "     (Ubuntu Server recommended, with cloud-init support)"
echo ""
echo "  2. Boot the VM: ./run_qemu.sh"
echo ""
echo "  3. Inside VM, load NVMeVirt:"
echo "     cd ~/nvmevirt && sudo insmod nvmev.ko memmap_start=1G memmap_size=512M cpus=2,3"
echo ""
echo "  4. Test with Erlang:"
echo "     erl -pa /path/to/mnesia_nvme/ebin"
echo "     {ok, H} = mnesia_nvme_device:open(\"/dev/ng0n1\")."
echo ""
echo "For development without VM, use the mock backend:"
echo "     application:set_env(mnesia_nvme, backend, mock)."
echo ""
