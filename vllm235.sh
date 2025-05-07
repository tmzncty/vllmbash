#!/bin/bash

# Exit immediately if a command exits with a non-zero status.
set -e
# Treat unset variables as an error when substituting.
set -u
# Pipelines return the exit status of the last command to exit with a non-zero status,
# or zero if no command exited with a non-zero status.
set -o pipefail

# --- Configuration ---
MINICONDA_INSTALL_PATH="$HOME/miniconda3"
CONDA_ENV_NAME="vllm"
PYTHON_VERSION="3.12" # Stellen Sie sicher, dass vLLM und ModelScope mit dieser Version kompatibel sind
# Verwenden Sie den Tsinghua-Spiegel für Miniconda
MINICONDA_DOWNLOAD_URL="https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/"
MINICONDA_SCRIPT_NAME="Miniconda3-latest-Linux-x86_64.sh"

# ModelScope Configuration
MODEL_ID_MODELSCOPE="Qwen/Qwen3-235B-A22B"
MODEL_CACHE_DIR="/AISPK" # Hauptverzeichnis für ModelScope-Downloads
VLLM_MODEL_PATH="$MODEL_CACHE_DIR/$MODEL_ID_MODELSCOPE" # vLLM erwartet den vollständigen Pfad zum heruntergeladenen Modell

# vLLM Server Configuration
TENSOR_PARALLEL_SIZE=8       # Für 8x L40 GPUs
GPU_MEMORY_UTILIZATION=0.9   # Adjust GPU memory usage fraction
MAX_NUM_SEQS=256             # Kann je nach Bedarf und Speicher angepasst werden
HOST_IP="0.0.0.0"
PORT="48556"                 # Neuer Port
LOG_FILE="$HOME/vllm_server.log" # Log-Datei für den Hintergrundprozess

# --- 1. System Updates and Dependencies ---
echo "Updating package lists and installing dependencies (wget, btop, build-essential, python3-pip, ufw)..."
# Hinweis: Wenn apt update langsam ist, sollten Sie Ihre System-APT-Quellen (/etc/apt/sources.list) auf einen regionalen Spiegel umstellen.
sudo apt update
sudo apt install -y wget btop build-essential python3-pip ufw
echo "System dependencies installed."

# --- 2. Download and Install Miniconda (Non-Interactive) ---
echo "Downloading Miniconda installer from Tsinghua mirror..."
if [ -f "$MINICONDA_SCRIPT_NAME" ]; then
    echo "Miniconda installer already downloaded."
else
    wget "$MINICONDA_DOWNLOAD_URL$MINICONDA_SCRIPT_NAME" -O "$MINICONDA_SCRIPT_NAME"
fi

echo "Installing Miniconda to $MINICONDA_INSTALL_PATH..."
if [ -d "$MINICONDA_INSTALL_PATH" ]; then
    echo "Miniconda directory already exists. Skipping installation."
else
    bash "$MINICONDA_SCRIPT_NAME" -b -p "$MINICONDA_INSTALL_PATH"
    echo "Miniconda installed."
    echo "Cleaning up Miniconda installer script..."
    rm "$MINICONDA_SCRIPT_NAME"
fi

# --- 3. Initialize Conda for this script and Configure Mirrors ---
echo "Initializing Conda environment for script..."
eval "$("$MINICONDA_INSTALL_PATH/bin/conda" shell.bash hook)"
"$MINICONDA_INSTALL_PATH/bin/conda" init bash > /dev/null 2>&1 || true

echo "Configuring Conda to use Tsinghua mirrors..."
"$MINICONDA_INSTALL_PATH/bin/conda" config --remove channels defaults || true # Optional aber oft empfohlen
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/pytorch/
"$MINICONDA_INSTALL_PATH/bin/conda" config --set show_channel_urls yes
echo "Conda channels configured to use Tsinghua mirrors."

# --- 4. Create and Setup Conda Environment ---
echo "Creating Conda environment '$CONDA_ENV_NAME' with Python $PYTHON_VERSION..."
if "$MINICONDA_INSTALL_PATH/bin/conda" info --envs | grep -q "^$CONDA_ENV_NAME\s"; then
   echo "Conda environment '$CONDA_ENV_NAME' already exists. Skipping creation."
else
    "$MINICONDA_INSTALL_PATH/bin/conda" create -n "$CONDA_ENV_NAME" python="$PYTHON_VERSION" -y
    echo "Conda environment '$CONDA_ENV_NAME' created."
fi

# --- 5. Install vLLM, ModelScope and other Python packages ---
echo "Activating Conda environment '$CONDA_ENV_NAME' for package installation..."
source "$MINICONDA_INSTALL_PATH/bin/activate" "$CONDA_ENV_NAME"

echo "Configuring pip to use Tsinghua mirror..."
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing vLLM, nvitop, and modelscope..."
pip install vllm nvitop modelscope "tf-keras>=2.13"

echo "vLLM, nvitop, and modelscope installed/updated successfully in '$CONDA_ENV_NAME'."

# --- 6. Download Model from ModelScope ---
echo "Checking for model $MODEL_ID_MODELSCOPE in $MODEL_CACHE_DIR..."

# 确保 MODEL_CACHE_DIR 存在，并且当前用户拥有其所有权
echo "Ensuring ModelScope cache directory exists: $MODEL_CACHE_DIR"
sudo mkdir -p "$MODEL_CACHE_DIR" # 如果目录不存在则创建，此时可能归属于 root

echo "Ensuring current user ($USER) owns $MODEL_CACHE_DIR..."
# 无论目录是否已存在，都确保当前用户是所有者
sudo chown "$USER":"$USER" "$MODEL_CACHE_DIR"
# 为了更加保险，明确给予用户读写执行权限
sudo chmod u+rwx "$MODEL_CACHE_DIR"

# Für ModelScope-Downloads: modelscope.cn ist die primäre Quelle.
# export MODELSCOPE_HUB_ENDPOINT="https://modelscope.cn/api/v1" # Dies ist oft der Standardwert

if [ -d "$VLLM_MODEL_PATH" ]; then
    echo "Model $MODEL_ID_MODELSCOPE already found in $VLLM_MODEL_PATH. Skipping download."
else
    echo "Downloading model $MODEL_ID_MODELSCOPE from ModelScope to $MODEL_CACHE_DIR..."
    # Die Umgebung muss aktiv sein, damit `python` und `modelscope` gefunden werden
    python -c "
from modelscope.hub.snapshot_download import snapshot_download
import os
os.environ['MODELSCOPE_CACHE'] = '$MODEL_CACHE_DIR'
# os.environ['MODELSCOPE_HUB_ENDPOINT'] = 'https://modelscope.cn/api/v1'
# os.environ['MODELSCOPE_DOWNLOAD_PARALLEL'] = '8'
# os.environ['MODELSCOPE_SDK_DEBUG'] = '1'

snapshot_download(
    '$MODEL_ID_MODELSCOPE',
    cache_dir='$MODEL_CACHE_DIR'
)
"
    echo "Model downloaded."
fi

# --- 7. Start vLLM Server (Background) ---
echo "--------------------------------------------------"
echo "Installation and model download complete."
echo "Starting vLLM OpenAI API server in the background..."
echo "Model: $VLLM_MODEL_PATH"
echo "Tensor Parallel Size: $TENSOR_PARALLEL_SIZE"
echo "Host: $HOST_IP"
echo "Port: $PORT"
echo "Log file: $LOG_FILE"
echo "--------------------------------------------------"

if [[ "$CONDA_DEFAULT_ENV" != "$CONDA_ENV_NAME" && "$CONDA_PREFIX" != "$MINICONDA_INSTALL_PATH/envs/$CONDA_ENV_NAME" ]]; then
    echo "Error: Failed to activate conda environment '$CONDA_ENV_NAME' properly. Exiting."
    "$MINICONDA_INSTALL_PATH/bin/conda" info --envs || echo "Failed to get conda info."
    exit 1
fi
echo "Conda environment '$CONDA_DEFAULT_ENV' is active."

nohup python -m vllm.entrypoints.openai.api_server \
    --model "$VLLM_MODEL_PATH" \
    --tensor-parallel-size "$TENSOR_PARALLEL_SIZE" \
    --trust-remote-code \
    --dtype bfloat16 \
    --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
    --max-num-seqs "$MAX_NUM_SEQS" \
    --host "$HOST_IP" \
    --port "$PORT" \
    --uvicorn-log-level debug > "$LOG_FILE" 2>&1 &

SERVER_PID=$!
echo "vLLM server started in background with PID $SERVER_PID."
echo "To view logs: tail -f $LOG_FILE"
echo "To stop the server: kill $SERVER_PID"
echo "Or use: pkill -f 'vllm.entrypoints.openai.api_server.*--port $PORT'"

# --- 8. Configure UFW Firewall ---
echo "Configuring UFW firewall..."
sudo ufw allow "$PORT"/tcp
sudo ufw status
echo "UFW rule for port $PORT/tcp added. If UFW was inactive, you might need to enable it (e.g., 'sudo ufw enable')."
echo "Ensure SSH (port 22) is allowed if you are enabling UFW for the first time: sudo ufw allow ssh"

echo "--------------------------------------------------"
echo "Script finished. vLLM server should be running."
echo "--------------------------------------------------"

exit 0
