FROM ubuntu:22.04

# Prevent interactive prompts during apt-get
ENV DEBIAN_FRONTEND=noninteractive

# Install required packages for driver building and module loading
# NOTE: gcc and make are required because nvidia-installer builds kernel modules
RUN apt-get update && apt-get install -y \
    wget \
    curl \
    kmod \
    binutils \
    pciutils \
    libelf-dev \
    gcc \
    make \
    && rm -rf /var/lib/apt/lists/*

# Driver version - can be overridden at build time
# UPDATED to 580.126.09 for Blackwell (RTX 5080) GSP firmware support
ARG DRIVER_VERSION=580.126.09
ENV DRIVER_VERSION=${DRIVER_VERSION}

# Pre-download the driver for layer caching (saves ~500MB download on each run)
RUN wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run" \
    -O /nvidia-driver.run && chmod +x /nvidia-driver.run

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

# Build libcuda_shim.so to bypass sm_120 (Blackwell) architecture block
# Usage: LD_PRELOAD=/nvidia-libs/libcuda_shim.so your_application
COPY libcuda_shim.c /tmp/
RUN gcc -shared -fPIC -o /usr/lib/libcuda_shim.so /tmp/libcuda_shim.c -ldl && \
    rm /tmp/libcuda_shim.c && \
    ls -la /usr/lib/libcuda_shim.so

# Set working directory
WORKDIR /

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["init"]
