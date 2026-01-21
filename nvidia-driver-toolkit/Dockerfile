FROM ubuntu:22.04

# Prevent interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages for driver building and module loading
# NOTE: gcc and make are required because nvidia-installer builds kernel modules
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    unzip \
    kmod \
    binutils \
    pciutils \
    libelf-dev \
    gcc \
    make \
    gnupg2 \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install nvidia-container-toolkit from NVIDIA repos
# This provides nvidia-container-runtime for proper GPU device passthrough
RUN curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
    && curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
       sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
       tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
    && apt-get update \
    && apt-get install -y nvidia-container-toolkit \
    && rm -rf /var/lib/apt/lists/*

# Driver version - can be overridden at build time
# UPDATED to 590.48.01 - FIRST version with official Blackwell (sm_120) CUDA support
ARG DRIVER_VERSION=590.48.01
ENV DRIVER_VERSION=${DRIVER_VERSION}

# NVRTC version for CUDA runtime compilation
ARG NVRTC_VERSION=11.3.58
ENV NVRTC_VERSION=${NVRTC_VERSION}

# Pre-download the driver for layer caching (saves ~500MB download on each run)
RUN wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run" \
    -O /nvidia-driver.run && chmod +x /nvidia-driver.run

# Pre-download NVRTC wheel for offline installation
RUN curl -fsSL -o /nvrtc.whl "https://developer.download.nvidia.com/compute/redist/nvidia-cuda-nvrtc/nvidia_cuda_nvrtc-${NVRTC_VERSION}-py3-none-manylinux1_x86_64.whl"

# Extract GSP firmware from the driver package
# GSP firmware is REQUIRED for CUDA on Turing+ GPUs (including Blackwell RTX 5080)
RUN /nvidia-driver.run --extract-only && \
    mkdir -p /firmware && \
    cp NVIDIA-Linux-x86_64-${DRIVER_VERSION}/firmware/*.bin /firmware/ 2>/dev/null || true && \
    ls -la /firmware/ && \
    rm -rf NVIDIA-Linux-x86_64-${DRIVER_VERSION}

# Copy entrypoint scripts
COPY entrypoint.sh common.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Set working directory
WORKDIR /

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["init"]
