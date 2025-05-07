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
MINICONDA_SCRIPT_NAME="Miniconda3-latest-Linux-x86_64.sh"

# ModelScope Configuration
MODEL_ID_MODELSCOPE="Qwen/Qwen3-235B-A22B"
MODEL_CACHE_DIR="/AISPK" # Hauptverzeichnis für ModelScope-Downloads
VLLM_MODEL_PATH="$MODEL_CACHE_DIR/$MODEL_ID_MODELSCOPE" # vLLM erwartet den vollständigen Pfad zum heruntergeladenen Modell

# vLLM Server Configuration
# MODEL_NAME wird jetzt durch VLLM_MODEL_PATH oben definiert
TENSOR_PARALLEL_SIZE=8           # Für 8x L40 GPUs
GPU_MEMORY_UTILIZATION=0.9       # Adjust GPU memory usage fraction
MAX_NUM_SEQS=256                 # Kann je nach Bedarf und Speicher angepasst werden
HOST_IP="0.0.0.0"
PORT="48556"                     # Neuer Port
LOG_FILE="$HOME/vllm_server.log" # Log-Datei für den Hintergrundprozess

# --- 1. System Updates and Dependencies ---
echo "Updating package lists and installing dependencies (wget, btop, build-essential, python3-pip, ufw)..."
sudo apt update
sudo apt install -y wget btop build-essential python3-pip ufw
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
# Die folgende Zeile kann Fehler ausgeben, wenn .bashrc nicht interaktiv ist, aber sie ist oft notwendig.
# Leiten Sie Fehler um, wenn sie stören, aber stellen Sie sicher, dass Conda initialisiert ist.
$MINICONDA_INSTALL_PATH/bin/conda init bash > /dev/null 2>&1 || true

# --- 4. Create and Setup Conda Environment ---
echo "Creating Conda environment '$CONDA_ENV_NAME' with Python $PYTHON_VERSION..."
if conda info --envs | grep -q "^$CONDA_ENV_NAME\s"; then
   echo "Conda environment '$CONDA_ENV_NAME' already exists. Skipping creation."
else
   conda create -n $CONDA_ENV_NAME python=$PYTHON_VERSION -y
   echo "Conda environment '$CONDA_ENV_NAME' created."
fi

# --- 5. Install vLLM, ModelScope and other Python packages ---
echo "Activating Conda environment '$CONDA_ENV_NAME' for package installation..."
# Wichtig: Aktivieren Sie die Umgebung, bevor Sie pip install ausführen, um sicherzustellen, dass Pakete im richtigen Environment landen.
# Dies ist eine sicherere Methode als `conda run` für mehrere pip-Befehle oder komplexe Installationen.
source "$MINICONDA_INSTALL_PATH/bin/activate" "$CONDA_ENV_NAME"

echo "Upgrading pip..."
pip install --upgrade pip

echo "Installing vLLM, nvitop, and modelscope..."
# tf-keras ist oft eine Abhängigkeit von modelscope oder bestimmten Modellen
pip install vllm nvitop modelscope "tf-keras>=2.13" # tf-keras hinzugefügt

echo "vLLM, nvitop, and modelscope installed/updated successfully in '$CONDA_ENV_NAME'."

# --- 6. Download Model from ModelScope ---
echo "Checking for model $MODEL_ID_MODELSCOPE in $MODEL_CACHE_DIR..."
# Erstellen Sie das Cache-Verzeichnis, falls es nicht existiert.
# Wichtig: Stellen Sie sicher, dass der ausführende Benutzer Schreibrechte für MODEL_CACHE_DIR hat.
# Wenn MODEL_CACHE_DIR /AISPK ist (Root-Level), benötigen Sie möglicherweise sudo hier oder müssen Berechtigungen vorher festlegen.
if [ ! -d "$MODEL_CACHE_DIR" ]; then
    echo "Creating ModelScope cache directory: $MODEL_CACHE_DIR"
    sudo mkdir -p "$MODEL_CACHE_DIR"
    # Ändern Sie den Besitzer auf den aktuellen Benutzer, damit ModelScope ohne sudo schreiben kann
    sudo chown "$USER":"$USER" "$MODEL_CACHE_DIR"
    # Für den Fall, dass MODEL_ID_MODELSCOPE Schrägstriche enthält und Unterverzeichnisse erstellt werden müssen
    # Dies wird von modelscope selbst gehandhabt, aber das Haupt-Cache-Verzeichnis muss existieren und beschreibbar sein.
fi

# Überprüfen, ob das spezifische Modellverzeichnis bereits existiert
if [ -d "$VLLM_MODEL_PATH" ]; then
    echo "Model $MODEL_ID_MODELSCOPE already found in $VLLM_MODEL_PATH. Skipping download."
else
    echo "Downloading model $MODEL_ID_MODELSCOPE from ModelScope to $MODEL_CACHE_DIR..."
    # Führen Sie den Download als Python-Befehl aus
    # Stellen Sie sicher, dass die Umgebung aktiv ist, damit `python` und `modelscope` gefunden werden
    python -c "
from modelscope.hub.snapshot_download import snapshot_download
import os
os.environ['MODELSCOPE_CACHE'] = '$MODEL_CACHE_DIR' # Setzen Sie die Umgebungsvariable für ModelScope
snapshot_download('$MODEL_ID_MODELSCOPE', cache_dir='$MODEL_CACHE_DIR', local_dir_layout='{model_id}') # Stellt sicher, dass der Pfad $MODEL_CACHE_DIR/$MODEL_ID_MODELSCOPE ist
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

# Die Umgebung ist bereits aktiv durch `source "$MINICONDA_INSTALL_PATH/bin/activate" "$CONDA_ENV_NAME"`
if [[ "$CONDA_DEFAULT_ENV" != "$CONDA_ENV_NAME" && "$CONDA_PREFIX" != "$MINICONDA_INSTALL_PATH/envs/$CONDA_ENV_NAME" ]]; then
    echo "Error: Failed to activate conda environment '$CONDA_ENV_NAME' properly. Exiting."
    conda info --envs || echo "Failed to get conda info."
    exit 1
fi
echo "Conda environment '$CONDA_DEFAULT_ENV' is active."

# Starten Sie den Server im Hintergrund mit nohup und leiten Sie die Ausgabe in eine Log-Datei um.
# Verwenden Sie trust-remote-code, wenn das Modell dies erfordert (typisch für viele Qwen-Modelle)
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

# PID des Hintergrundprozesses abrufen
SERVER_PID=$!
echo "vLLM server started in background with PID $SERVER_PID."
echo "To view logs: tail -f $LOG_FILE"
echo "To stop the server: kill $SERVER_PID"
echo "Or use: pkill -f 'vllm.entrypoints.openai.api_server.*--port $PORT'"

# --- 8. Configure UFW Firewall ---
echo "Configuring UFW firewall..."
sudo ufw allow "$PORT"/tcp
sudo ufw status # Zeigt den aktuellen Status an
# Optional: sudo ufw enable, falls UFW nicht aktiv ist (seien Sie vorsichtig, wenn Sie SSH verwenden, stellen Sie sicher, dass Port 22 erlaubt ist)
# Optional: sudo ufw reload, um Regeln neu zu laden, falls UFW bereits aktiv ist
echo "UFW rule for port $PORT/tcp added. If UFW was inactive, you might need to enable it (e.g., 'sudo ufw enable')."
echo "Ensure SSH (port 22) is allowed if you are enabling UFW for the first time: sudo ufw allow ssh"

# Conda-Umgebung nach dem Starten des Servers nicht mehr deaktivieren, da der Server in dieser Umgebung laufen soll.
# Das Deaktivieren würde hier keinen Sinn machen, da der Server als Hintergrundprozess weiterläuft.
# Der `nohup` Prozess ist von der aktuellen Shell entkoppelt.

echo "--------------------------------------------------"
echo "Script finished. vLLM server should be running."
echo "--------------------------------------------------"

exit 0
