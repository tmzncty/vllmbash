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
# vLLM erwartet den vollständigen Pfad zum heruntergeladenen Modell.
# ModelScope lädt 'Qwen/Qwen3-235B-A22B' in '$MODEL_CACHE_DIR/Qwen/Qwen3-235B-A22B' herunter.
VLLM_MODEL_PATH="$MODEL_CACHE_DIR/$MODEL_ID_MODELSCOPE"

# vLLM Server Configuration
TENSOR_PARALLEL_SIZE=8      # Für 8x L40 GPUs
GPU_MEMORY_UTILIZATION=0.9  # Adjust GPU memory usage fraction
MAX_NUM_SEQS=256            # Kann je nach Bedarf und Speicher angepasst werden
HOST_IP="0.0.0.0"
PORT="48556"                # Neuer Port
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
# Source conda.sh to make 'conda' command available to the script if not already in PATH
# This is more robust than relying on 'eval' output for some shells or non-interactive contexts.
if [ -f "$MINICONDA_INSTALL_PATH/etc/profile.d/conda.sh" ]; then
    source "$MINICONDA_INSTALL_PATH/etc/profile.d/conda.sh"
else
    echo "Error: conda.sh not found in Miniconda installation. Please check the path."
    exit 1
fi
# Initialize conda for bash. The > /dev/null 2>&1 || true silences output and prevents exit on error if already initialized.
"$MINICONDA_INSTALL_PATH/bin/conda" init bash > /dev/null 2>&1 || true

echo "Configuring Conda to use Tsinghua mirrors..."
"$MINICONDA_INSTALL_PATH/bin/conda" config --remove channels defaults || true # Optional aber oft empfohlen
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/main/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/pkgs/r/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/conda-forge/
"$MINICONDA_INSTALL_PATH/bin/conda" config --add channels https://mirrors.tuna.tsinghua.edu.cn/anaconda/cloud/pytorch/ # For PyTorch specific builds if needed
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
# It's crucial to activate the environment for pip installations to go to the right place.
# The 'conda activate' command is preferred for interactive use and scripts that source .bashrc.
# For scripts, 'source activate' or directly calling pip from the env's bin is more reliable.
# Here, we ensure conda command is available and then activate.
conda activate "$CONDA_ENV_NAME"

echo "Configuring pip to use Tsinghua mirror..."
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing vLLM, nvitop, and modelscope..."
# Ensure tf-keras is quoted if it contains version specifiers that shell might interpret
pip install vllm nvitop modelscope "tf-keras>=2.13"

echo "vLLM, nvitop, and modelscope installed/updated successfully in '$CONDA_ENV_NAME'."

# --- 6. Download Model from ModelScope ---
echo "Checking for model $MODEL_ID_MODELSCOPE in $MODEL_CACHE_DIR..."

# Ensure MODEL_CACHE_DIR exists, and current user owns the specific model sub-directory path
# ModelScope will create subdirectories like Qwen/Qwen3-235B-A22B inside MODEL_CACHE_DIR
echo "Ensuring ModelScope base cache directory exists: $MODEL_CACHE_DIR"
sudo mkdir -p "$MODEL_CACHE_DIR" # Create base directory if it doesn't exist

echo "Ensuring current user ($USER) owns the base cache directory $MODEL_CACHE_DIR..."
# This is important if MODEL_CACHE_DIR was created by root or another user previously.
sudo chown -R "$USER":"$(id -gn "$USER")" "$MODEL_CACHE_DIR"
# Grant user read/write/execute permissions on the base cache directory
sudo chmod -R u+rwx "$MODEL_CACHE_DIR"

# For ModelScope downloads: modelscope.cn is the primary source.
# export MODELSCOPE_HUB_ENDPOINT="https://modelscope.cn/api/v1" # This is often the default

if [ -d "$VLLM_MODEL_PATH" ]; then
    echo "Model $MODEL_ID_MODELSCOPE already found in $VLLM_MODEL_PATH. Skipping download."
else
    echo "Downloading model $MODEL_ID_MODELSCOPE from ModelScope to $MODEL_CACHE_DIR..."
    # The environment must be active for `python` and `modelscope` to be found correctly.
    # The python -c block will inherit the activated Conda environment.
    python -c "
from modelscope.hub.snapshot_download import snapshot_download
import os
# Set environment variable for ModelScope cache, though cache_dir in snapshot_download is more direct.
os.environ['MODELSCOPE_CACHE'] = '$MODEL_CACHE_DIR'
# Optional: Set other ModelScope environment variables if needed
# os.environ['MODELSCOPE_HUB_ENDPOINT'] = 'https://modelscope.cn/api/v1'
# os.environ['MODELSCOPE_DOWNLOAD_PARALLEL'] = '8' # For parallel downloads
# os.environ['MODELSCOPE_SDK_DEBUG'] = '1' # For debugging ModelScope SDK

print(f'Attempting to download {os.environ.get("MODELSCOPE_MODEL_ID", "$MODEL_ID_MODELSCOPE")} to cache_dir={os.environ.get("MODELSCOPE_CACHE", "$MODEL_CACHE_DIR")}')

snapshot_download(
    model_id='$MODEL_ID_MODELSCOPE',
    cache_dir='$MODEL_CACHE_DIR' # ModelScope will create subdirs like MODEL_ID_MODELSCOPE within this
)
"
    echo "Model download attempt finished."
    if [ -d "$VLLM_MODEL_PATH" ]; then
        echo "Model successfully located at $VLLM_MODEL_PATH after download."
    else
        echo "Error: Model directory $VLLM_MODEL_PATH not found after download attempt. Please check logs or ModelScope configuration."
        exit 1
    fi
fi

# --- 7. Start vLLM Server (Background) ---
echo "--------------------------------------------------"
echo "Installation and model download complete."
echo "Starting vLLM OpenAI API server in the background..."
echo "Model: $VLLM_MODEL_PATH"
echo "Tokenizer Path: $VLLM_MODEL_PATH (inferred or same as model)"
echo "Tensor Parallel Size: $TENSOR_PARALLEL_SIZE"
echo "Host: $HOST_IP"
echo "Port: $PORT"
echo "Log file: $LOG_FILE"
echo "--------------------------------------------------"

# Ensure the correct conda environment is active for the nohup command
if [[ "${CONDA_DEFAULT_ENV:-x}" != "$CONDA_ENV_NAME" && "${CONDA_PREFIX:-x}" != "$MINICONDA_INSTALL_PATH/envs/$CONDA_ENV_NAME" ]]; then
    echo "Error: Conda environment '$CONDA_ENV_NAME' is not active. Attempting to activate..."
    conda activate "$CONDA_ENV_NAME"
    # Double check activation
    if [[ "${CONDA_DEFAULT_ENV:-x}" != "$CONDA_ENV_NAME" && "${CONDA_PREFIX:-x}" != "$MINICONDA_INSTALL_PATH/envs/$CONDA_ENV_NAME" ]]; then
        echo "Error: Failed to activate conda environment '$CONDA_ENV_NAME' properly. Exiting."
        "$MINICONDA_INSTALL_PATH/bin/conda" info --envs || echo "Failed to get conda info."
        exit 1
    fi
fi
echo "Conda environment '$CONDA_DEFAULT_ENV' is active for starting the server."

# The actual command to start the vLLM server
# Note: Comments are NOT placed after line continuation characters '\'
nohup python -m vllm.entrypoints.openai.api_server \
    --model "$VLLM_MODEL_PATH" \
    --tokenizer "$VLLM_MODEL_PATH" \
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
# Wait a few seconds to give the server a chance to start or fail
sleep 5
if ps -p $SERVER_PID > /dev/null; then
   echo "Server process $SERVER_PID is running."
   echo "To view logs: tail -f $LOG_FILE"
   echo "To stop the server: kill $SERVER_PID"
   echo "Or use: pkill -f 'vllm.entrypoints.openai.api_server.*--port $PORT'"
else
   echo "Error: Server process $SERVER_PID did not start or exited prematurely."
   echo "Please check the log file for errors: $LOG_FILE"
   cat "$LOG_FILE" # Display the log file content if server failed to start
   exit 1
fi


# --- 8. Configure UFW Firewall ---
echo "Configuring UFW firewall..."
if command -v ufw &> /dev/null; then
    sudo ufw allow "$PORT"/tcp
    sudo ufw status verbose
    echo "UFW rule for port $PORT/tcp added/checked. If UFW was inactive, you might need to enable it (e.g., 'sudo ufw enable')."
    echo "Ensure SSH (port 22) is allowed if you are enabling UFW for the first time: sudo ufw allow ssh"
else
    echo "UFW command not found. Skipping firewall configuration. Please configure your firewall manually if needed."
fi

echo "--------------------------------------------------"
echo "Script finished. vLLM server should be running."
echo "--------------------------------------------------"

exit 0
