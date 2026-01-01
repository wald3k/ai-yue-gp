#!/bin/bash

set -euo pipefail  # Exit on error, show commands, handle pipes safely

echo "🔧 Starting YuEGP container startup script..."

# Set up arguments
YUEGP_PROFILE=${YUEGP_PROFILE:-1}
YUEGP_CUDA_IDX=${YUEGP_CUDA_IDX:-0}
YUEGP_ENABLE_ICL=${YUEGP_ENABLE_ICL:-0}
YUEGP_TRANSFORMER_PATCH=${YUEGP_TRANSFORMER_PATCH:-0}
YUEGP_AUTO_UPDATE=${YUEGP_AUTO_UPDATE:-0}
YUEGP_SERVER_USER=${YUEGP_SERVER_USER:-""}
YUEGP_SERVER_PASSWORD=${YUEGP_SERVER_PASSWORD:-""}

CACHE_HOME="/workspace/cache"
export HF_HOME="${CACHE_HOME}/huggingface"
export TORCH_HOME="${CACHE_HOME}/torch"

echo "📂 Setting up cache directories..."
mkdir -p "${CACHE_HOME}" "${HF_HOME}" "${TORCH_HOME}" /workspace/output

# Clone or update YuEGP
YUEGP_HOME="${CACHE_HOME}/YuEGP"
if [ ! -d "$YUEGP_HOME" ]; then
    echo "📥 Unnpacking YuEGP repository..."
    mkdir -p "$YUEGP_HOME"
    tar -xzvf YuEGP.tar.gz --strip-components=1 -C "$YUEGP_HOME"
fi
if [[ "$YUEGP_AUTO_UPDATE" == "1" ]]; then
    echo "🔄 Updating the YuEGP repository..."
    git -C "$YUEGP_HOME" reset --hard
    git -C "$YUEGP_HOME" pull
fi

# Clone or update xcodec_mini_infer
XCODEC_HOME="${CACHE_HOME}/xcodec_mini_infer"
if [ ! -d "$XCODEC_HOME" ]; then
    echo "📥 Unpacking the xcodec_mini_infer repository..."
    mkdir -p "$XCODEC_HOME"
    tar -xzvf xcodec_mini_infer.tar.gz --strip-components=1 -C "$XCODEC_HOME"
fi
if [[ "$YUEGP_AUTO_UPDATE" == "1" ]]; then
    echo "🔄 Updating xcodec_mini_infer repository..."
    git -C "$XCODEC_HOME" reset --hard
    git -C "$XCODEC_HOME" pull
fi

# Link xcodec_mini_infer
INFERENCE_HOME="${YUEGP_HOME}/inference"
ln -sfn "${XCODEC_HOME}" "${INFERENCE_HOME}/xcodec_mini_infer"

# Install dependencies
VENV_HOME="${CACHE_HOME}/venv"
echo "📦 Installing dependencies..."
if [ ! -d "$VENV_HOME" ]; then
    # Create virtual environment, but re-use globally installed packages if available (e.g. via base container)
    python3 -m venv "$VENV_HOME" --system-site-packages
fi
source "${VENV_HOME}/bin/activate"

# Ensure latest pip version
pip install --no-cache-dir --upgrade pip wheel

# Install required dependencies
pip install --no-cache-dir --upgrade pip
#pip install torch==2.5.1 torchvision torchaudio --index-url https://download.pytorch.org/whl/test/cu124
pip uninstall -y torch torchvision torchaudio || true
pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 \
  --extra-index-url https://download.pytorch.org/whl/cu124



pip install --no-cache-dir --root-user-action=ignore -r "$YUEGP_HOME/requirements.txt"
pip install --no-cache-dir wheel
pip install --no-cache-dir ninja cmake packaging pybind11
pip install --no-cache-dir flash-attn --no-build-isolation
#pip install --no-cache-dir --root-user-action=ignore flash-attn --no-build-isolation
python - <<'EOF'
import torch
try:
    from flash_attn import flash_attn_func
    print("✅ FlashAttention is available")
except Exception as e:
    print("❌ FlashAttention NOT available:", e)
    print("⚠️ Will rely on SDPA")
EOF



# Applying transformer patch as per YuEGP documentation
if [[ "$YUEGP_TRANSFORMER_PATCH" == "1" ]]; then
    echo "🔨 Applying transformer patch..."
    ln -sfn "${VENV_HOME}" "${YUEGP_HOME}/venv"
    cd "$YUEGP_HOME" || exit 1
    source patchtransformers.sh
fi

# Build command line argds and start the service
YUEGP_ARGS=" \
    --profile ${YUEGP_PROFILE} \
    --cuda_idx ${YUEGP_CUDA_IDX} \
    --output_dir /workspace/output \
    --keep_intermediate \
    --server_name 0.0.0.0 \
    --server_port 7860"

if [[ "$YUEGP_ENABLE_ICL" == "1" ]]; then
    echo "🔨 Enabling audio prompt..."
    YUEGP_ARGS="$YUEGP_ARGS --icl"
fi


USE_SDPA=0
python - <<'EOF' || USE_SDPA=1
from flash_attn import flash_attn_func
EOF

if [[ "$USE_SDPA" == "1" ]]; then
    echo "⚠️ FlashAttention unavailable, enabling SDPA fallback"
    YUEGP_ARGS="$YUEGP_ARGS --sdpa"
fi



# Ensuring that all output is flushed to the console, and that stderr is redirected to stdout and log
echo "🚀 Starting YuEGP service..."
cd "$INFERENCE_HOME" || exit 1
python3 -u gradio_server.py ${YUEGP_ARGS} 2>&1 | tee "${CACHE_HOME}/output.log"
echo "❌ The YuEGP service has terminated."
