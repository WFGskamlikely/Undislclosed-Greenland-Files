#!/usr/bin/env bash
set -euo pipefail

LOG=/var/log/do-startup-a1111.log
exec > >(tee -a "$LOG") 2>&1

echo "==> A1111 startup provisioning begin: $(date -Is)"

# ---- Config ----
SD_USER="do-shark"                         # matches DO tutorial
SD_HOME="/home/${SD_USER}"
SD_REPO_DIR="${SD_HOME}/stable-diffusion-webui"
PORT="7860"
LISTEN="0.0.0.0"

# Optional: set to a direct URL to a .safetensors/.ckpt model to auto-download
MODEL_URL="${MODEL_URL:-}"
MODEL_PATH_REL="models/Stable-diffusion/model.safetensors"

# ---- 1) (Optional but recommended) Create non-root user (DO tutorial) ----
if ! id -u "${SD_USER}" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "${SD_USER}"
  usermod -aG sudo "${SD_USER}"
fi

# ---- 2) Install system dependencies (DO tutorial) ----
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  wget git python3 python3-venv \
  ca-certificates curl \
  ffmpeg

# ---- Quick GPU sanity check (not in doc, but harmless) ----
if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi || true
fi

# ---- 3) Clone repo (DO tutorial) ----
if [[ ! -d "${SD_REPO_DIR}/.git" ]]; then
  sudo -u "${SD_USER}" -H bash -lc "cd ~ && git clone https://github.com/AUTOMATIC1111/stable-diffusion-webui.git"
else
  echo "Repo already exists at ${SD_REPO_DIR}"
fi

# ---- 4/5) Create venv + install requirements (DO tutorial) ----
# The DO tutorial uses venv activation + pip install -r requirements.txt.
# A1111 also has its own installer logic when you run webui.sh, but we’ll match the doc.
sudo -u "${SD_USER}" -H bash -lc "
  cd '${SD_REPO_DIR}'
  if [[ ! -d venv ]]; then
    python3 -m venv venv
  fi
  source venv/bin/activate
  pip install -U pip setuptools wheel
  pip install -r requirements.txt
"

# ---- 6) Update xFormers for CUDA support (DO tutorial) ----
sudo -u "${SD_USER}" -H bash -lc "
  cd '${SD_REPO_DIR}'
  source venv/bin/activate
  pip uninstall -y xformers || true
  pip install xformers --extra-index-url https://download.pytorch.org/whl/nightly/cu118
"

# ---- 7) Optional: download a model (DO tutorial pattern) ----
if [[ -n "${MODEL_URL}" ]]; then
  echo "Downloading model from MODEL_URL into ${SD_REPO_DIR}/${MODEL_PATH_REL}"
  sudo -u "${SD_USER}" -H bash -lc "
    cd '${SD_REPO_DIR}'
    mkdir -p models/Stable-diffusion
    wget -O '${MODEL_PATH_REL}' '${MODEL_URL}'
  "
else
  echo "MODEL_URL not set; skipping model download."
  echo "You must place a model in: ${SD_REPO_DIR}/models/Stable-diffusion/"
fi

# ---- 8) Optional: gpustat (DO tutorial) ----
sudo -u "${SD_USER}" -H bash -lc "
  cd '${SD_REPO_DIR}'
  source venv/bin/activate
  pip install -U gpustat
" || true

# ---- Create systemd service to start on boot (fast restarts) ----
SERVICE=/etc/systemd/system/stable-diffusion-webui.service
cat > "${SERVICE}" <<EOF
[Unit]
Description=AUTOMATIC1111 Stable Diffusion WebUI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SD_USER}
Group=${SD_USER}
WorkingDirectory=${SD_REPO_DIR}
Environment=PYTHONUNBUFFERED=1
# Listen on all interfaces like typical droplet usage
ExecStart=${SD_REPO_DIR}/venv/bin/python ${SD_REPO_DIR}/launch.py --listen ${LISTEN} --port ${PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now stable-diffusion-webui.service

echo "==> Done. Check logs with:"
echo "    journalctl -u stable-diffusion-webui -f"
echo "Web UI should be on: http://<DROPLET_IP>:${PORT}"
echo "Provisioning log: ${LOG}"
echo "==> A1111 startup provisioning end: $(date -Is)"
