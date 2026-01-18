#!/bin/bash
# Copyright (c) 2024, jefflouisma. All rights reserved.
# Unified NVIDIA Driver Toolkit - Main Entrypoint

set -eu

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

#
# Find and load nvidia-uvm.ko from Harvester's nvidia-driver-runtime container overlay
# This is the solution for Harvester's immutable OS where we can't compile modules
#
load_nvidia_uvm_from_overlay() {
    log_info "=== Loading nvidia-uvm from Container Overlay ==="
    
    # Check if already loaded
    if module_loaded nvidia-uvm; then
        log_info "nvidia-uvm already loaded"
        return 0
    fi
    
    # Define cache location
    local CACHE_DIR="${NVIDIA_BASE_DIR:-/var/lib/nvidia}/modules"
    local CACHED_MODULE="${CACHE_DIR}/nvidia-uvm.ko"
    
    # Try cached module first
    if [ -f "$CACHED_MODULE" ]; then
        log_info "Found cached nvidia-uvm.ko at ${CACHED_MODULE}"
        if nsenter -t 1 -m -u -i -n -p -- insmod "$CACHED_MODULE" 2>/dev/null; then
            log_info "SUCCESS: Loaded nvidia-uvm from cache"
            create_nvidia_uvm_devices
            return 0
        else
            log_warn "Cached module failed to load, searching for fresh copy..."
        fi
    fi
    
    # Search for nvidia-uvm.ko in containerd overlays
    log_info "Searching containerd overlays for nvidia-uvm.ko..."
    local OVERLAY_BASE="/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots"
    
    # Use host namespace to find the module  
    local UVM_PATH=$(nsenter -t 1 -m -u -i -n -p -- find "$OVERLAY_BASE" -name "nvidia-uvm.ko" -path "*/usr/lib/modules/*/kernel/drivers/video/*" -type f 2>/dev/null | head -1)
    
    if [ -z "$UVM_PATH" ]; then
        # Try alternate location (build directory)
        UVM_PATH=$(nsenter -t 1 -m -u -i -n -p -- find "$OVERLAY_BASE" -name "nvidia-uvm.ko" -path "*/kernel-open/*" -type f 2>/dev/null | head -1)
    fi
    
    if [ -z "$UVM_PATH" ]; then
        log_error "nvidia-uvm.ko not found in container overlays"
        log_error "Make sure the nvidia-driver-runtime addon has run at least once"
        return 1
    fi
    
    log_info "Found nvidia-uvm.ko at: ${UVM_PATH}"
    
    # Create cache directory and copy module
    nsenter -t 1 -m -u -i -n -p -- mkdir -p "$CACHE_DIR"
    nsenter -t 1 -m -u -i -n -p -- cp "$UVM_PATH" "$CACHED_MODULE"
    log_info "Cached nvidia-uvm.ko to ${CACHED_MODULE}"
    
    # Load the module via insmod on host
    if nsenter -t 1 -m -u -i -n -p -- insmod "$CACHED_MODULE" 2>/dev/null; then
        log_info "SUCCESS: nvidia-uvm loaded via insmod"
        create_nvidia_uvm_devices
        return 0
    else
        log_error "Failed to load nvidia-uvm.ko"
        return 1
    fi
}

#
# Create nvidia-uvm device nodes
#
create_nvidia_uvm_devices() {
    log_info "Creating nvidia-uvm device nodes..."
    
    # Get major number from /proc/devices
    local MAJOR=$(nsenter -t 1 -m -u -i -n -p -- cat /proc/devices | grep nvidia-uvm | awk '{print $1}')
    
    if [ -z "$MAJOR" ]; then
        log_warn "Could not determine nvidia-uvm major number"
        return 1
    fi
    
    log_info "nvidia-uvm major number: ${MAJOR}"
    
    # Create device nodes on host
    nsenter -t 1 -m -u -i -n -p -- rm -f /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
    nsenter -t 1 -m -u -i -n -p -- mknod /dev/nvidia-uvm c "$MAJOR" 0
    nsenter -t 1 -m -u -i -n -p -- chmod 666 /dev/nvidia-uvm
    nsenter -t 1 -m -u -i -n -p -- mknod /dev/nvidia-uvm-tools c "$MAJOR" 1
    nsenter -t 1 -m -u -i -n -p -- chmod 666 /dev/nvidia-uvm-tools
    
    log_info "Created /dev/nvidia-uvm and /dev/nvidia-uvm-tools"
    return 0
}

#
# Install the NVIDIA driver (builds kernel modules)
#
install_driver() {
    log_info "=== Installing NVIDIA Driver ==="
    
    if [ ! -f /nvidia-driver.run ]; then
        log_error "Driver package not found at /nvidia-driver.run"
        return 1
    fi
    
    log_info "Running NVIDIA installer for driver ${DRIVER_VERSION}..."
    
    # Run the installer in silent mode
    /nvidia-driver.run \
        --silent \
        --no-questions \
        --ui=none \
        --no-install-compat32-libs \
        --no-backup \
        --no-nouveau-check \
        --no-x-check \
        --no-cc-version-check \
        2>&1 || {
            log_warn "nvidia-installer exited with non-zero status (may be normal)"
        }
    
    log_info "Driver installation completed"
    
    # Persist the built kernel modules
    log_info "Persisting kernel modules..."
    for module in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
        persist_module "$module" || true
    done
}

#
# Load all required NVIDIA kernel modules
# CRITICAL: This includes nvidia-uvm which is required for CUDA!
#
load_all_modules() {
    log_info "=== Loading NVIDIA Kernel Modules ==="
    
    # Load prerequisite modules
    log_info "Loading prerequisite modules..."
    modprobe -a i2c_core ipmi_msghandler ipmi_devintf 2>/dev/null || true
    
    # Load NVIDIA modules in order - ALL 5 MODULES
    # CRITICAL: nvidia-uvm is required for CUDA context creation!
    local modules=(nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem)
    
    for module in "${modules[@]}"; do
        load_module "$module" || log_warn "Failed to load ${module}"
    done
    
    # Verify critical modules
    log_info "=== Module Verification ==="
    lsmod | grep nvidia || log_error "No NVIDIA modules loaded!"
    
    if module_loaded nvidia-uvm; then
        log_info "SUCCESS: nvidia-uvm is loaded (CUDA support enabled)"
    else
        log_error "CRITICAL: nvidia-uvm NOT loaded (CUDA will fail!)"
    fi
}

#
# Full initialization
#
init() {
    log_info "========================================"
    log_info "  NVIDIA Driver Toolkit - Unified"
    log_info "  Driver Version: ${DRIVER_VERSION}"
    log_info "========================================"
    
    # Check current state of nvidia modules
    local nvidia_loaded=$(module_loaded nvidia && echo "yes" || echo "no")
    local nvidia_uvm_loaded=$(module_loaded nvidia-uvm && echo "yes" || echo "no")
    
    log_info "Current state: nvidia=${nvidia_loaded}, nvidia-uvm=${nvidia_uvm_loaded}"
    
    if [ "$nvidia_loaded" = "yes" ] && [ "$nvidia_uvm_loaded" = "yes" ]; then
        # Both loaded - just ensure devices and libraries are set up
        log_info "NVIDIA driver with UVM already loaded"
        create_device_nodes
        
        if [ ! -f "${NVIDIA_LIB_DIR}/libcuda.so.1" ]; then
            install_libraries
            create_icd_files
        fi
    elif [ "$nvidia_loaded" = "yes" ]; then
        # nvidia loaded but nvidia-uvm missing - this is the common case on Harvester
        log_info "nvidia loaded but nvidia-uvm MISSING - loading from container overlay..."
        
        # Use the overlay extraction method (works on Harvester's immutable OS)
        load_nvidia_uvm_from_overlay || log_warn "Failed to load nvidia-uvm from overlay"
        
        # Install libraries and create devices
        install_libraries
        create_icd_files
        create_device_nodes
    else
        # No nvidia at all - full installation needed
        log_info "No NVIDIA modules loaded - full installation required"
        install_driver
        load_all_modules
        install_libraries
        create_icd_files
        create_device_nodes
    fi
    
    # Final status
    log_info "========================================"
    log_info "  NVIDIA Driver Toolkit Ready"
    log_info "========================================"
    
    # Show nvidia-smi if available
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi || true
    elif [ -x "${NVIDIA_BIN_DIR}/nvidia-smi" ]; then
        "${NVIDIA_BIN_DIR}/nvidia-smi" || true
    fi
    
    # Summary
    local lib_count=$(ls "${NVIDIA_LIB_DIR}"/*.so* 2>/dev/null | wc -l || echo 0)
    local module_count=$(ls "${NVIDIA_MODULE_DIR}"/*.ko* 2>/dev/null | wc -l || echo 0)
    
    log_info "Summary:"
    log_info "  - Persisted modules: ${module_count}"
    log_info "  - Installed libraries: ${lib_count}"
    log_info "  - nvidia-uvm loaded: $(module_loaded nvidia-uvm && echo 'YES' || echo 'NO')"
    log_info "  - /dev/nvidia-uvm exists: $([ -e /dev/nvidia-uvm ] && echo 'YES' || echo 'NO')"
    
    # Keep container alive
    log_info "Entering sleep loop (container alive for library serving)..."
    exec sleep infinity
}

#
# Just load modules (for reboot scenarios)
#
load() {
    log_info "=== Loading persisted NVIDIA modules ==="
    
    load_all_modules
    create_device_nodes
    
    log_info "Module loading complete"
    exec sleep infinity
}

#
# Usage
#
usage() {
    cat >&2 <<EOF
NVIDIA Driver Toolkit - Unified

Usage: $0 COMMAND

Commands:
  init    Full initialization (install driver, load modules, extract libs)
  load    Load persisted modules only (for reboot scenarios)

Environment Variables:
  DRIVER_VERSION           Driver version (default: 580.119.02)
  NVIDIA_BASE_DIR          Base directory for persistence (default: /var/lib/nvidia)
  GPU_DIRECT_RDMA_ENABLED  Enable nvidia-peermem for RDMA (default: false)
EOF
    exit 1
}

#
# Main
#
if [ $# -eq 0 ]; then
    usage
fi

command="${1:-}"
case "${command}" in
    init) init ;;
    load) load ;;
    *) usage ;;
esac
