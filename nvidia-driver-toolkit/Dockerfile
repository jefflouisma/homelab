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
ARG DRIVER_VERSION=580.119.02
ENV DRIVER_VERSION=${DRIVER_VERSION}

# Pre-download the driver for layer caching (saves ~500MB download on each run)
RUN wget -q "https://download.nvidia.com/XFree86/Linux-x86_64/${DRIVER_VERSION}/NVIDIA-Linux-x86_64-${DRIVER_VERSION}.run" \
    -O /nvidia-driver.run && chmod +x /nvidia-driver.run

# Copy entrypoint scripts
COPY entrypoint.sh common.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh

# Set working directory
WORKDIR /

# Entrypoint
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["init"]
