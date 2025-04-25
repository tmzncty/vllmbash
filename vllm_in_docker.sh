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
PYTHON_VERSION="3.12"
MINICONDA_SCRIPT_NAME="Miniconda3-latest-Linux-x86_64.sh"

# vLLM Server Configuration
MODEL_NAME="Qwen/Qwen2.5-VL-32B-Instruct" # Or choose another model
TENSOR_PARALLEL_SIZE=2                  # Adjust based on your GPU setup
GPU_MEMORY_UTILIZATION=0.9              # Adjust GPU memory usage fraction
MAX_NUM_SEQS=256
HOST_IP="0.0.0.0"
PORT="8000"

# --- 1. System Updates and Dependencies ---
echo "Updating package lists and installing dependencies (wget, btop)..."
# Assuming running as root (like root@...), 'sudo' is removed.
apt update
apt install -y wget btop build-essential python3-pip
echo "System dependencies installed."

# --- 2. Download and Install Miniconda (Non-Interactive) ---
echo "Downloading Miniconda installer..."
if [ -f "$MINICONDA_SCRIPT_NAME" ]; then
    echo "Miniconda installer already downloaded."
else
    wget https://repo.anaconda.com/miniconda/$MINICONDA_SCRIPT_NAME -O $MINICONDA_SCRIPT_NAME
fi

echo "Installing Miniconda to $MINICONDA_INSTALL_PATH..."
if [ -d "$MINICONDA_INSTALL_PATH" ]; then
    echo "Miniconda directory already exists. Skipping installation."
else
    bash $MINICONDA_SCRIPT_NAME -b -p $MINICONDA_INSTALL_PATH
    echo "Miniconda installed."
    echo "Cleaning up Miniconda installer script..."
    rm $MINICONDA_SCRIPT_NAME
fi

# --- 3. Initialize Conda for this script ---
echo "Initializing Conda environment for script..."
eval "$($MINICONDA_INSTALL_PATH/bin/conda shell.bash hook)"
$MINICONDA_INSTALL_PATH/bin/conda init bash > /dev/null 2>&1

# --- 4. Create and Setup Conda Environment ---
echo "Creating Conda environment '$CONDA_ENV_NAME' with Python $PYTHON_VERSION..."
if conda info --envs | grep -q "^$CONDA_ENV_NAME\s"; then
   echo "Conda environment '$CONDA_ENV_NAME' already exists. Skipping creation."
else
   conda create -n $CONDA_ENV_NAME python=$PYTHON_VERSION -y
   echo "Conda environment '$CONDA_ENV_NAME' created."
fi

# --- 5. Install vLLM and other Python packages ---
echo "Installing/Updating vLLM and nvitop into the '$CONDA_ENV_NAME' environment..."
conda run -n $CONDA_ENV_NAME pip install --upgrade pip
conda run -n $CONDA_ENV_NAME pip install vllm nvitop
echo "vLLM and nvitop installed/updated successfully in '$CONDA_ENV_NAME'."

# --- 6. Start vLLM Server (Using conda activate) ---
echo "--------------------------------------------------"
echo "Installation complete. Activating environment and starting vLLM OpenAI API server..."
echo "Model: $MODEL_NAME"
echo "Tensor Parallel Size: $TENSOR_PARALLEL_SIZE"
echo "Host: $HOST_IP"
echo "Port: $PORT"
echo "Press Ctrl+C to stop the server."
echo "--------------------------------------------------"

conda activate $CONDA_ENV_NAME

if [[ "$CONDA_DEFAULT_ENV" != "$CONDA_ENV_NAME" && "$CONDA_PREFIX" != "$MINICONDA_INSTALL_PATH/envs/$CONDA_ENV_NAME" ]]; then
    echo "Error: Failed to activate conda environment '$CONDA_ENV_NAME'. Exiting."
    conda info --envs || echo "Failed to get conda info."
    exit 1
fi

echo "Conda environment '$CONDA_DEFAULT_ENV' activated successfully."

# Run the server command directly, using the CORRECT log level argument
python -m vllm.entrypoints.openai.api_server \
    --model "$MODEL_NAME" \
    --tensor-parallel-size $TENSOR_PARALLEL_SIZE \
    --trust-remote-code \
    --dtype bfloat16 \
    --gpu-memory-utilization $GPU_MEMORY_UTILIZATION \
    --max-num-seqs $MAX_NUM_SEQS \
    --host $HOST_IP \
    --port $PORT \
    --uvicorn-log-level debug # CORRECTED ARGUMENT

conda deactivate || echo "Note: conda deactivate command finished (ignore errors if any)."

echo "vLLM server stopped."

exit 0
