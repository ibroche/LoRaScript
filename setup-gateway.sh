#!/bin/bash

set -e

echo "🚀 Installation complète du système LoRaWAN Gateway SX1303 Dockerisé"

# ===============================
# 1. Installer Docker si absent
# ===============================
if ! command -v docker &> /dev/null; then
    echo "🐳 Docker non détecté, installation en cours..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker $USER
    echo "✅ Docker installé. Tu dois peut-être redémarrer pour activer les droits Docker."
fi

# ===============================
# 1bis. Installer Docker Compose v2 si absent
# ===============================
if ! command -v docker compose &> /dev/null; then
    echo "🔧 Installation de Docker Compose v2..."
    DOCKER_CONFIG=${DOCKER_CONFIG:-$HOME/.docker}
    mkdir -p $DOCKER_CONFIG/cli-plugins
    curl -SL https://github.com/docker/compose/releases/download/v2.24.2/docker-compose-linux-armv7 -o $DOCKER_CONFIG/cli-plugins/docker-compose
    chmod +x $DOCKER_CONFIG/cli-plugins/docker-compose
    echo "✅ Docker Compose installé (v2)"
    sudo ln -s $HOME/.docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
fi


# ===============================
# 2. Créer le projet Docker
# ===============================
PROJECT_DIR="$HOME/sx1303-gateway-docker"
CONFIG_DIR="$PROJECT_DIR/config"

mkdir -p "$CONFIG_DIR"

# Dockerfile
cat > "$PROJECT_DIR/Dockerfile" <<'EOF'
FROM debian:bullseye

RUN apt-get update && apt-get install -y \
    git build-essential cmake libusb-1.0-0-dev libudev-dev \
    gpiod libgpiod-dev \
    && apt-get clean

WORKDIR /opt

RUN git clone https://github.com/Lora-net/sx1302_hal.git

WORKDIR /opt/sx1302_hal
RUN make all
EOF

# docker-compose.yml
cat > "$PROJECT_DIR/docker-compose.yml" <<'EOF'
version: '3.7'

services:
  lora-gateway:
    build: .
    container_name: sx1303_gateway
    privileged: true
    restart: unless-stopped
    devices:
      - /dev/spidev0.0
      - /dev/gpiochip0
    volumes:
      - ./config/global_conf.json:/opt/sx1302_hal/packet_forwarder/lora_pkt_fwd/global_conf.json
      - ./config/reset_lgw.sh:/opt/sx1302_hal/util_chip_id/reset_lgw.sh
    working_dir: /opt/sx1302_hal
    entrypoint: ["/bin/bash", "-c", "./util_chip_id/reset_lgw.sh && ./packet_forwarder/lora_pkt_fwd/lora_pkt_fwd"]
EOF

# Script de reset GPIO via libgpiod
cat > "$CONFIG_DIR/reset_lgw.sh" <<'EOF'
#!/bin/bash

SX1302_RESET_PIN=23
SX1261_RESET_PIN=23
SX1302_POWER_EN_PIN=18
SX1302_CLK_EN_PIN=22
AD5338R_RESET_PIN=13

gpioset -m time -s 0 gpiochip0 $SX1302_POWER_EN_PIN=1
gpioset -m time -s 0 gpiochip0 $SX1302_RESET_PIN=0
gpioset -m time -s 0 gpiochip0 $SX1302_RESET_PIN=1
gpioset -m time -s 0 gpiochip0 $SX1302_CLK_EN_PIN=1
gpioset -m time -s 0 gpiochip0 $AD5338R_RESET_PIN=1
EOF

chmod +x "$CONFIG_DIR/reset_lgw.sh"

# Fichier de config TTN générique (à éditer manuellement)
cat > "$CONFIG_DIR/global_conf.json" <<'EOF'
{
  "gateway_conf": {
    "server_address": "eu1.cloud.thethings.network",
    "serv_port_up": 1700,
    "serv_port_down": 1700,
    "ref_latitude": 0,
    "ref_longitude": 0,
    "ref_altitude": 0,
    "gps": false,
    "fake_gps": false,
    "forward_crc_valid": true,
    "forward_crc_error": false,
    "forward_crc_disabled": false
  }
}
EOF

# Script de démarrage
cat > "$PROJECT_DIR/start.sh" <<'EOF'
#!/bin/bash
docker-compose up --build -d
EOF

chmod +x "$PROJECT_DIR/start.sh"

# ===============================
# 3. Lancer la gateway
# ===============================
echo "🚧 Build du container SX1303 LoRa Gateway..."
cd "$PROJECT_DIR"
./start.sh

echo "✅ Installation complète."
echo "➡️ Tu peux maintenant éditer ta conf ici : $CONFIG_DIR/global_conf.json"
echo "➡️ Logs de la gateway : docker logs -f sx1303_gateway"

echo "🔧 Création du service systemd sx1303-gateway..."

cat <<EOF | sudo tee /etc/systemd/system/sx1303-gateway.service > /dev/null
[Unit]
Description=SX1303 LoRaWAN Gateway Docker
After=network-online.target docker.service
Wants=network-online.target

[Service]
ExecStartPre=/bin/bash -c '[[ -e /dev/spidev0.0 ]] && [[ -e /dev/gpiochip0 ]] || (echo "❌ Matériel non détecté (SPI ou GPIO manquant)" && exit 1)'
ExecStart=/usr/bin/docker-compose -f $PROJECT_DIR/docker-compose.yml up
WorkingDirectory=$PROJECT_DIR
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable sx1303-gateway.service
