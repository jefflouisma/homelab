#!/bin/bash
# Copyright (c) 2024, jefflouisma. All rights reserved.
# Unified NVIDIA Driver Toolkit - Common Functions

set -eu

# Directories for persistent storage
NVIDIA_BASE_DIR="${NVIDIA_BASE_DIR:-/var/lib/nvidia}"
NVIDIA_LIB_DIR="${NVIDIA_BASE_DIR}/lib"
NVRTC_VERSION="${NVRTC_VERSION:-11.3.58}"
NVRTC_WHEEL="nvidia_cuda_nvrtc-${NVRTC_VERSION}-py3-none-manylinux1_x86_64.whl"
NVRTC_URL="https://developer.download.nvidia.com/compute/redist/nvidia-cuda-nvrtc/${NVRTC_WHEEL}"
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

# Check if a kernel module is loaded ON THE HOST
# Uses nsenter since container has hostPID: true
module_loaded() {
    local module_name="${1//-/_}"  # Replace hyphens with underscores
    # Use nsenter to check host's loaded modules (requires hostPID: true)
    nsenter -t 1 -m -u -i -n -p -- cat /proc/modules 2>/dev/null | grep -q "^${module_name} "
}

# Load a kernel module ON THE HOST
# Uses nsenter since container has hostPID: true
load_module() {
    local module_name="$1"
    local module_underscore="${module_name//-/_}"

    if module_loaded "$module_name"; then
        log_info "${module_name} already loaded on HOST"
        return 0
    fi

    # Try loading via nsenter modprobe on host
    log_info "Loading ${module_name} on HOST via nsenter..."
    if nsenter -t 1 -m -u -i -n -p -- modprobe "$module_name" 2>/dev/null; then
        log_info "${module_name} loaded successfully on HOST"
        return 0
    fi

    # Try loading from persisted .ko via nsenter insmod
    local ko_file="${NVIDIA_MODULE_DIR}/${module_name}.ko"
    if [ -f "$ko_file" ]; then
        log_info "Loading ${module_name} from persisted module on HOST..."
        if nsenter -t 1 -m -u -i -n -p -- insmod "$ko_file" 2>/dev/null; then
            log_info "${module_name} loaded successfully from cache on HOST"
            return 0
        fi
    fi

    log_error "Failed to load ${module_name} on HOST"
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

install_nvrtc() {
    local nvrtc_target="${NVIDIA_LIB_DIR}/libnvrtc.so.${NVRTC_VERSION}"
    if [ -f "$nvrtc_target" ]; then
        log_info "NVRTC ${NVRTC_VERSION} already installed"
        return 0
    fi

    log_info "Installing NVRTC ${NVRTC_VERSION}..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local wheel_path="${tmp_dir}/${NVRTC_WHEEL}"

    if [ -f /nvrtc.whl ]; then
        cp -f /nvrtc.whl "$wheel_path"
    else
        curl -fsSL -o "$wheel_path" "$NVRTC_URL"
    fi

    unzip -joq -d "${tmp_dir}/nvrtc" "$wheel_path"
    chmod 755 "${tmp_dir}"/nvrtc/libnvrtc* 2>/dev/null || true
    cp -v "${tmp_dir}"/nvrtc/libnvrtc* "${NVIDIA_LIB_DIR}/" 2>/dev/null || true

    if [ -f "${NVIDIA_LIB_DIR}/libnvrtc.so.${NVRTC_VERSION}" ]; then
        ln -sf "libnvrtc.so.${NVRTC_VERSION}" "${NVIDIA_LIB_DIR}/libnvrtc.so" 2>/dev/null || true
    fi
    if [ -f "${NVIDIA_LIB_DIR}/libnvrtc-builtins.so.${NVRTC_VERSION}" ]; then
        ln -sf "libnvrtc-builtins.so.${NVRTC_VERSION}" "${NVIDIA_LIB_DIR}/libnvrtc-builtins.so" 2>/dev/null || true
    fi

    rm -rf "$tmp_dir"
    log_info "NVRTC ${NVRTC_VERSION} installed to ${NVIDIA_LIB_DIR}"
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

    install_nvrtc

    # Cleanup
    rm -rf "$extract_dir"

    local lib_count=$(ls "${NVIDIA_LIB_DIR}"/*.so* 2>/dev/null | wc -l)
    log_info "Installed ${lib_count} libraries to ${NVIDIA_LIB_DIR}"
}
