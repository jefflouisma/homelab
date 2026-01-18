#!/bin/bash
# Copyright (c) 2024, jefflouisma. All rights reserved.
# Unified NVIDIA Driver Toolkit - Common Functions

set -eu

# Directories for persistent storage
NVIDIA_BASE_DIR="${NVIDIA_BASE_DIR:-/var/lib/nvidia}"
NVIDIA_LIB_DIR="${NVIDIA_BASE_DIR}/lib"
NVIDIA_MODULE_DIR="${NVIDIA_BASE_DIR}/modules"
NVIDIA_JSON_DIR="${NVIDIA_BASE_DIR}/json"
NVIDIA_BIN_DIR="${NVIDIA_BASE_DIR}/bin"

DRIVER_VERSION="${DRIVER_VERSION:-580.119.02}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# Check if a kernel module is loaded
module_loaded() {
    local module_name="${1//-/_}"  # Replace hyphens with underscores
    lsmod | grep -q "^${module_name} "
}

# Load a kernel module
load_module() {
    local module_name="$1"
    local module_underscore="${module_name//-/_}"
    
    if module_loaded "$module_name"; then
        log_info "${module_name} already loaded"
        return 0
    fi
    
    # Try loading from persisted .ko first
    local ko_file="${NVIDIA_MODULE_DIR}/${module_name}.ko"
    if [ -f "$ko_file" ]; then
        log_info "Loading ${module_name} from persisted module..."
        if insmod "$ko_file" 2>/dev/null; then
            log_info "${module_name} loaded successfully from cache"
            return 0
        else
            log_warn "Failed to load ${module_name} from cache, trying modprobe..."
        fi
    fi
    
    # Fallback to modprobe
    if modprobe "$module_name" 2>/dev/null; then
        log_info "${module_name} loaded successfully via modprobe"
        return 0
    fi
    
    log_error "Failed to load ${module_name}"
    return 1
}

# Persist a kernel module to our storage
persist_module() {
    local module_name="$1"
    local kernel_version=$(uname -r)
    
    mkdir -p "${NVIDIA_MODULE_DIR}"
    
    # Search for the module in standard locations
    local search_paths=(
        "/lib/modules/${kernel_version}/kernel/drivers/video/${module_name}.ko"
        "/lib/modules/${kernel_version}/kernel/drivers/video/${module_name}.ko.xz"
        "/lib/modules/${kernel_version}/kernel/drivers/video/${module_name}.ko.zst"
        "/lib/modules/${kernel_version}/updates/${module_name}.ko"
        "/lib/modules/${kernel_version}/extra/${module_name}.ko"
    )
    
    for path in "${search_paths[@]}"; do
        if [ -f "$path" ]; then
            log_info "Persisting ${path} to ${NVIDIA_MODULE_DIR}/"
            cp -v "$path" "${NVIDIA_MODULE_DIR}/"
            return 0
        fi
    done
    
    log_warn "Could not find ${module_name}.ko to persist"
    return 1
}

# Create NVIDIA device nodes
create_device_nodes() {
    log_info "Creating NVIDIA device nodes..."
    
    # nvidia-smi creates most device nodes automatically
    if command -v nvidia-smi &>/dev/null; then
        nvidia-smi > /dev/null 2>&1 || true
    fi
    
    # Ensure nvidia-uvm devices exist
    if module_loaded nvidia-uvm; then
        local uvm_major=$(cat /proc/devices 2>/dev/null | grep nvidia-uvm | awk '{print $1}')
        if [ -n "$uvm_major" ]; then
            log_info "Creating nvidia-uvm devices with major ${uvm_major}"
            mknod -m 666 /dev/nvidia-uvm c "$uvm_major" 0 2>/dev/null || true
            mknod -m 666 /dev/nvidia-uvm-tools c "$uvm_major" 1 2>/dev/null || true
        fi
    fi
    
    # Fix permissions on all NVIDIA devices
    chmod 666 /dev/nvidia* 2>/dev/null || true
    chmod 666 /dev/dri/* 2>/dev/null || true
    
    # List created devices
    log_info "NVIDIA devices:"
    ls -la /dev/nvidia* 2>/dev/null || log_warn "No /dev/nvidia* devices found"
    
    log_info "DRI devices:"
    ls -la /dev/dri/* 2>/dev/null || log_warn "No /dev/dri/* devices found"
}

# Create EGL/Vulkan ICD configuration files
create_icd_files() {
    log_info "Creating EGL/Vulkan ICD files..."
    
    mkdir -p "${NVIDIA_JSON_DIR}"
    
    # EGL vendor file
    cat > "${NVIDIA_JSON_DIR}/10_nvidia.json" <<EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libEGL_nvidia.so.0"
    }
}
EOF
    
    # Vulkan ICD file
    cat > "${NVIDIA_JSON_DIR}/nvidia_icd.json" <<EOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "libGLX_nvidia.so.0",
        "api_version": "1.3"
    }
}
EOF
    
    log_info "Created ICD files in ${NVIDIA_JSON_DIR}"
}

# Extract and install userspace libraries from driver package
install_libraries() {
    log_info "Installing userspace libraries..."
    
    mkdir -p "${NVIDIA_LIB_DIR}"
    
    # Extract driver package
    local extract_dir="/tmp/nvidia-extract"
    rm -rf "$extract_dir"
    
    if [ -f /nvidia-driver.run ]; then
        log_info "Extracting from pre-downloaded driver..."
        /nvidia-driver.run --extract-only --target "$extract_dir"
    else
        log_error "No driver package found at /nvidia-driver.run"
        return 1
    fi
    
    # Copy all .so files
    log_info "Copying library files..."
    for lib in "$extract_dir"/*.so* "$extract_dir"/*.so; do
        if [ -f "$lib" ]; then
            cp -v "$lib" "${NVIDIA_LIB_DIR}/" 2>/dev/null || true
        fi
    done
    
    # Copy binaries
    mkdir -p "${NVIDIA_BIN_DIR}"
    for bin in nvidia-smi nvidia-persistenced nvidia-modprobe; do
        if [ -f "$extract_dir/$bin" ]; then
            cp -v "$extract_dir/$bin" "${NVIDIA_BIN_DIR}/"
            chmod +x "${NVIDIA_BIN_DIR}/$bin"
        fi
    done
    
    # Create critical symlinks
    log_info "Creating library symlinks..."
    cd "${NVIDIA_LIB_DIR}"
    
    # libcuda symlinks
    ln -sf libcuda.so.${DRIVER_VERSION} libcuda.so.1 2>/dev/null || true
    ln -sf libcuda.so.1 libcuda.so 2>/dev/null || true
    
    # libnvidia-ml symlinks
    ln -sf libnvidia-ml.so.${DRIVER_VERSION} libnvidia-ml.so.1 2>/dev/null || true
    ln -sf libnvidia-ml.so.1 libnvidia-ml.so 2>/dev/null || true
    
    # EGL symlinks
    ln -sf libEGL_nvidia.so.${DRIVER_VERSION} libEGL_nvidia.so.0 2>/dev/null || true
    
    # GLX symlinks
    ln -sf libGLX_nvidia.so.${DRIVER_VERSION} libGLX_nvidia.so.0 2>/dev/null || true
    
    # GLES symlinks
    ln -sf libGLESv2_nvidia.so.${DRIVER_VERSION} libGLESv2_nvidia.so.2 2>/dev/null || true
    
    # Video codec symlinks
    ln -sf libnvcuvid.so.${DRIVER_VERSION} libnvcuvid.so.1 2>/dev/null || true
    ln -sf libnvcuvid.so.1 libnvcuvid.so 2>/dev/null || true
    ln -sf libnvidia-encode.so.${DRIVER_VERSION} libnvidia-encode.so.1 2>/dev/null || true
    ln -sf libnvidia-encode.so.1 libnvidia-encode.so 2>/dev/null || true
    
    # Cleanup
    rm -rf "$extract_dir"
    
    local lib_count=$(ls "${NVIDIA_LIB_DIR}"/*.so* 2>/dev/null | wc -l)
    log_info "Installed ${lib_count} libraries to ${NVIDIA_LIB_DIR}"
}
