#!/bin/bash
# Build script for custom Jellyfin NVIDIA image
# For Harvester HCI with consumer GPU

set -e

IMAGE_NAME="jellyfin-nvidia"
IMAGE_TAG="10.10.3-cuda12.6"
REGISTRY="${REGISTRY:-}"  # Set to your registry if pushing

echo "=== Building Jellyfin NVIDIA Image ==="
echo "Image: ${IMAGE_NAME}:${IMAGE_TAG}"

# Build the image
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -t ${IMAGE_NAME}:latest .

echo "=== Build Complete ==="
echo "Local image: ${IMAGE_NAME}:${IMAGE_TAG}"

# Push to registry if specified
if [ -n "$REGISTRY" ]; then
    echo "=== Pushing to ${REGISTRY} ==="
    docker tag ${IMAGE_NAME}:${IMAGE_TAG} ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
    docker tag ${IMAGE_NAME}:latest ${REGISTRY}/${IMAGE_NAME}:latest
    docker push ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}
    docker push ${REGISTRY}/${IMAGE_NAME}:latest
    echo "Pushed: ${REGISTRY}/${IMAGE_NAME}:${IMAGE_TAG}"
fi

echo "=== Done ==="
