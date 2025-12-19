#!/bin/bash
# Jetson/ARM64 Setup Script for XiaoZhi Server (ESP32 Backend)
# - Build cache friendly
# - Robust buildx handling (older/newer buildx)
# - Jetson iptables/raw workaround helper

set -euo pipefail

BASE_DIR="${BASE_DIR:-/main/xiaozhi-server}"
DATA_DIR="$BASE_DIR/data"
MODEL_DIR="$BASE_DIR/models/SenseVoiceSmall"
MODEL_URL="https://modelscope.cn/models/iic/SenseVoiceSmall/resolve/master/model.pt"
MODEL_PATH="$MODEL_DIR/model.pt"

IMAGE_NAME="${IMAGE_NAME:-xiaozhi-esp32-server:server-base}"
DOCKERFILE_BASE="${DOCKERFILE_BASE:-./Dockerfile-server-base.jetson}"
COMPOSE_FILE="${COMPOSE_FILE:-$(pwd)/main/xiaozhi-server/docker-compose_arm.yml}"

# Optional knobs
NO_CACHE="${NO_CACHE:-0}"            # set 1 to force no-cache builds
PIP_INDEX_URL="${PIP_INDEX_URL:-}"   # e.g. https://mirrors.aliyun.com/pypi/simple/
PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-mirrors.aliyun.com}"

echo "📁 Checking directories..."
mkdir -p "$DATA_DIR" "$MODEL_DIR"

echo "📥 Checking model..."
if [ ! -f "$MODEL_PATH" ]; then
  curl -fL --progress-bar "$MODEL_URL" -o "$MODEL_PATH"
else
  echo "✅ Model already present: $MODEL_PATH"
fi

echo "🐳 Checking Docker..."
if ! command -v docker >/dev/null 2>&1; then
  echo "❌ Docker not found. Install Docker first, then re-run."
  exit 1
fi

# ---- Jetson iptables/raw known issue helper ----
# If your kernel lacks CONFIG_IP_NF_RAW / iptable_raw, Docker may fail with:
# "Unable to enable DIRECT ACCESS FILTERING - DROP rule ... iptables ... table `raw` ... Table does not exist"
#
# Workaround (security tradeoff): set DOCKER_INSECURE_NO_IPTABLES_RAW=1 for dockerd.
# See: NVIDIA forum threads / moby issue discussions.
if sudo docker info >/dev/null 2>&1; then
  : # ok
else
  echo "⚠️ Docker daemon not healthy; if you see iptables/raw errors on Jetson, apply the workaround:"
  echo "   sudo mkdir -p /etc/systemd/system/docker.service.d"
  echo "   printf '[Service]\nEnvironment=DOCKER_INSECURE_NO_IPTABLES_RAW=1\n' | sudo tee /etc/systemd/system/docker.service.d/override.conf"
  echo "   sudo systemctl daemon-reload && sudo systemctl restart docker"
fi

echo "🔧 Ensuring buildx..."
if ! docker buildx version >/dev/null 2>&1; then
  echo "❌ buildx not available. Install the buildx plugin, e.g.:"
  echo "   sudo apt-get install -y docker-buildx-plugin"
  exit 1
fi

# Create/use a builder in a way that works across buildx versions
BUILDER_NAME="${BUILDER_NAME:-jetsonbuilder}"
if ! docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
  echo "🔧 Creating buildx builder: $BUILDER_NAME"
  docker buildx create --name "$BUILDER_NAME" >/dev/null
fi
# Older buildx may not support --use on create; use explicit 'use'
docker buildx use "$BUILDER_NAME"
docker buildx inspect --bootstrap >/dev/null

echo "🏗️ Building image: $IMAGE_NAME"
BUILD_ARGS=()
[ -n "$PIP_INDEX_URL" ] && BUILD_ARGS+=(--build-arg "PIP_INDEX_URL=$PIP_INDEX_URL" --build-arg "PIP_TRUSTED_HOST=$PIP_TRUSTED_HOST")

CACHE_FLAGS=()
if [ "$NO_CACHE" = "1" ]; then
  CACHE_FLAGS+=(--no-cache)
fi

# On Jetson (native arm64), --platform linux/arm64 is still fine and keeps the intent explicit.
# Use --load so the result is available to 'docker compose' without pushing.
docker buildx build   "${CACHE_FLAGS[@]}"   --platform linux/arm64   --load   -t "$IMAGE_NAME"   -f "$DOCKERFILE_BASE"   "${BUILD_ARGS[@]}"   .

echo "🚀 Starting services with Docker Compose (ARM64): $COMPOSE_FILE"
if [ -f "$COMPOSE_FILE" ]; then
  docker compose -f "$COMPOSE_FILE" up -d --build
else
  echo "❌ Compose file not found: $COMPOSE_FILE"
  exit 1
fi

# Optional: prompt for secret
PUBLIC_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "🔗 Server management panel:"
echo "  - Local:  http://127.0.0.1:8002/"
echo "  - Public: http://$PUBLIC_IP:8002/"
echo ""
echo "If you want to auto-write server.secret into $DATA_DIR/.config.yaml, paste it now."
read -r -p "Please enter server.secret (leave blank to skip): " SECRET_KEY || true

CONFIG_FILE="$DATA_DIR/.config.yaml"
if [ -n "${SECRET_KEY:-}" ]; then
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y python3-yaml
  fi
  python3 - <<EOF
import yaml, os
config_path = "$CONFIG_FILE"
config = {}
if os.path.exists(config_path):
    with open(config_path, "r") as f:
        config = yaml.safe_load(f) or {}
config['manager-api'] = {'url': 'http://xiaozhi-esp32-server-web:8002/xiaozhi', 'secret': "$SECRET_KEY"}
with open(config_path, "w") as f:
    yaml.dump(config, f, allow_unicode=True)
EOF
  docker restart xiaozhi-esp32-server || true
  echo "✅ Secret key written; container restarted."
else
  echo "⚠️ Skipped secret configuration."
fi

LOCAL_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "✅ Done"
echo "Admin Panel:  http://$LOCAL_IP:8002"
echo "WebSocket:    ws://$LOCAL_IP:8000/xiaozhi/v1/"
