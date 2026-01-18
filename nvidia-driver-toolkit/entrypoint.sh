#!/bin/bash
# Copyright (c) 2024, jefflouisma. All rights reserved.
# Unified NVIDIA Driver Toolkit - Main Entrypoint

set -eu

# Source common functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

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
    
    # Check if already fully initialized
    if module_loaded nvidia && module_loaded nvidia-uvm; then
        log_info "NVIDIA driver with UVM already loaded"
        
        # Still need to ensure devices and libraries are set up
        create_device_nodes
        
        if [ ! -f "${NVIDIA_LIB_DIR}/libcuda.so.1" ]; then
            install_libraries
            create_icd_files
        fi
    else
        # Full installation needed
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
