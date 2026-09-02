#!/bin/bash

set -Eeo pipefail

export DEBIAN_FRONTEND=noninteractive

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

log() {
    echo "[$(date -Is)] $*"
}

wait_for_apt() {
    log "Waiting for APT/DPKG locks..."

    local counter=0
    local max_attempts=120

    if ! command -v fuser >/dev/null 2>&1; then
        log "fuser not found, waiting 15 seconds before APT operation..."
        sleep 15
        return 0
    fi

    while \
        fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || \
        fuser /var/cache/apt/archives/lock >/dev/null 2>&1
    do
        counter=$((counter + 1))

        if [ "$counter" -ge "$max_attempts" ]; then
            log "ERROR: APT lock did not clear within 10 minutes."
            return 1
        fi

        log "APT/DPKG busy, waiting 5 seconds..."
        sleep 5
    done
}

apt_retry() {
    local attempt

    for attempt in 1 2 3; do
        wait_for_apt

        if $SUDO "$@"; then
            return 0
        fi

        log "APT operation failed - attempt ${attempt}/3"
        sleep 10
    done

    log "ERROR: APT operation failed after 3 attempts."
    return 1
}

log "========================================="
log "LABTP OpenFOAM 14 image customization"
log "========================================="

#
# Validate base OS
#
source /etc/os-release

log "Base OS: ${PRETTY_NAME}"

if [ "${VERSION_ID}" != "22.04" ]; then
    log "ERROR: This image customization expects Ubuntu 22.04."
    exit 1
fi

#
# Capture existing HPC/MPI stack for troubleshooting
#
log "Existing MPI binaries before customization:"

command -v mpirun || true
command -v mpicc || true

mpirun --version 2>/dev/null | head -n 3 || true

#
# Stabilize package manager
#
wait_for_apt

$SUDO dpkg --configure -a

apt_retry apt-get update

#
# Base packages
#
apt_retry apt-get install -y \
    --no-install-recommends \
    ca-certificates \
    wget \
    gnupg \
    software-properties-common \
    psmisc

#
# OpenFOAM dependencies may require Universe
#
log "Enabling Ubuntu Universe repository..."

$SUDO add-apt-repository -y universe

#
# Configure official OpenFOAM Foundation repository
#
log "Configuring OpenFOAM Foundation repository..."

wget -qO- https://dl.openfoam.org/gpg.key \
    | $SUDO tee /etc/apt/trusted.gpg.d/openfoam.asc >/dev/null

$SUDO rm -f /etc/apt/sources.list.d/*dl_openfoam_org*list

$SUDO add-apt-repository -y \
    "http://dl.openfoam.org/ubuntu main dev"

apt_retry apt-get update

#
# Install the OpenMPI implementation we validated in LABTP
#
log "Installing Ubuntu OpenMPI..."

apt_retry apt-get install -y \
    --no-install-recommends \
    openmpi-bin \
    libopenmpi-dev

#
# Make Ubuntu OpenMPI the default MPI implementation
#
if update-alternatives --list mpi 2>/dev/null \
    | grep -qx '/usr/lib/openmpi/include'; then

    log "Setting OpenMPI as default MPI implementation..."

    $SUDO update-alternatives \
        --set mpi /usr/lib/openmpi/include
fi

#
# Validate MPI before OpenFOAM installation
#
if ! command -v mpicc >/dev/null 2>&1; then
    log "ERROR: mpicc is unavailable."
    exit 1
fi

if ! command -v mpirun >/dev/null 2>&1; then
    log "ERROR: mpirun is unavailable."
    exit 1
fi

log "MPI compiler: $(command -v mpicc)"
log "MPI runtime:  $(command -v mpirun)"

mpirun --version | head -n 3

#
# Install OpenFOAM 14
#
log "Installing OpenFOAM 14..."

apt_retry apt-get install -y \
    --no-install-recommends \
    openfoam14

#
# System-wide OpenFOAM environment
#
log "Creating OpenFOAM profile..."

cat <<'EOF' | $SUDO tee /etc/profile.d/openfoam14.sh >/dev/null
if [ -f /opt/openfoam14/etc/bashrc ]; then
    . /opt/openfoam14/etc/bashrc
fi
EOF

$SUDO chmod 0644 /etc/profile.d/openfoam14.sh

#
# Permanent MPI network configuration
#
# LABTP Fsv2 compute nodes contain:
#
#   eth0    -> Azure VNet
#   docker0 -> local Docker bridge
#
# Multi-node OpenMPI was verified to work after forcing eth0.
#
log "Configuring OpenMPI networking..."

OPENMPI_MCA_CONF="/etc/openmpi/openmpi-mca-params.conf"

$SUDO mkdir -p /etc/openmpi
$SUDO touch "$OPENMPI_MCA_CONF"

#
# Make script idempotent
#
$SUDO sed -i -E \
    '/^[[:space:]]*(btl_tcp_if_include|oob_tcp_if_include)[[:space:]]*=/d' \
    "$OPENMPI_MCA_CONF"

cat <<'EOF' | $SUDO tee -a "$OPENMPI_MCA_CONF" >/dev/null

# LABTP CycleCloud HPC networking
# Prevent OpenMPI from selecting docker0 for multi-node communication.
btl_tcp_if_include = eth0
oob_tcp_if_include = eth0
EOF

#
# Validate resulting installation
#
log "Validating OpenFOAM..."

bash <<'EOF'
set -e

source /opt/openfoam14/etc/bashrc

echo "OpenFOAM version:"
foamVersion

echo "foamRun:"
command -v foamRun

echo "blockMesh:"
command -v blockMesh

echo "simpleFoam:"
command -v simpleFoam

echo "mpicc:"
command -v mpicc

echo "mpirun:"
command -v mpirun

foamRun -help >/dev/null 2>&1
blockMesh -help >/dev/null 2>&1
EOF

log "Validating MPI network configuration..."

grep -E \
    '^[[:space:]]*(btl_tcp_if_include|oob_tcp_if_include)[[:space:]]*=' \
    "$OPENMPI_MCA_CONF"

#
# Cleanup image
#
log "Cleaning APT cache..."

$SUDO apt-get clean
$SUDO rm -rf /var/lib/apt/lists/*

log "========================================="
log "OpenFOAM image customization SUCCESS"
log "========================================="
