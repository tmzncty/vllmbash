import os
import requests
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from modelscope.hub.snapshot_download import snapshot_download # 用于重新下载

# --- 配置 ---
MODEL_API_URL = "https://modelscope.cn/api/v1/models/Qwen/Qwen3-235B-A22B/repo/files?Revision=master&Root="
LOCAL_MODEL_DIR = "/AISPK/Qwen/Qwen3-235B-A22B/" # 您的本地模型目录
MODEL_ID_MODELSCOPE = "Qwen/Qwen3-235B-A22B"
MODEL_SCOPE_CACHE_DIR = "/AISPK" # snapshot_download 使用的 cache_dir

# --- 辅助函数 ---
def get_official_file_metadata():
    """从 ModelScope API 获取所有文件的元数据"""
    print(f"Fetching official file metadata from: {MODEL_API_URL}")
    try:
        response = requests.get(MODEL_API_URL, timeout=60) # 增加超时
        response.raise_for_status()
        data = response.json()
        if data.get("Code") == 200 and "Data" in data and "Files" in data["Data"]:
            metadata = {}
            for f_info in data["Data"]["Files"]:
                # 只关心 blob 类型的文件，不关心树形目录等
                if f_info.get("Type") == "blob":
                    metadata[f_info["Name"]] = {
                        "sha256": f_info["Sha256"].lower(), # 统一转小写
                        "size": f_info["Size"]
                    }
            print(f"Successfully fetched metadata for {len(metadata)} files.")
            return metadata
        else:
            print(f"Error: API response format unexpected or error code. Response: {data}")
            return None
    except requests.exceptions.RequestException as e:
        print(f"Error fetching official metadata: {e}")
        return None
    except json.JSONDecodeError as e:
        print(f"Error decoding JSON from API response: {e}")
        return None

def calculate_local_sha256_and_size(filepath):
    """计算本地文件的 SHA256 哈希值和大小"""
    sha256 = hashlib.sha256()
    try:
        size = os.path.getsize(filepath)
        with open(filepath, 'rb') as f:
            for block in iter(lambda: f.read(65536), b''): # 64k block size
                sha256.update(block)
        return sha256.hexdigest().lower(), size # 统一转小写
    except FileNotFoundError:
        return None, -1 # 文件不存在
    except Exception as e:
        print(f"Error calculating SHA256/size for {os.path.basename(filepath)}: {e}")
        return "error", -2 # 计算出错

def attempt_redownload():
    """
    尝试让 modelscope snapshot_download 重新下载/校验整个模型仓库。
    """
    print(f"\nAttempting to re-download/verify entire model '{MODEL_ID_MODELSCOPE}'...")
    try:
        os.environ['MODELSCOPE_CACHE'] = MODEL_SCOPE_CACHE_DIR
        os.environ['MODELSCOPE_SDK_DEBUG'] = '1' # 开启SDK调试日志

        snapshot_download(
            MODEL_ID_MODELSCOPE,
            cache_dir=MODEL_SCOPE_CACHE_DIR
        )
        print(f"Re-download/verification attempt for '{MODEL_ID_MODELSCOPE}' completed.")
        return True
    except Exception as e:
        print(f"Error during re-download attempt for '{MODEL_ID_MODELSCOPE}': {e}")
        return False

# --- 主逻辑 ---
if __name__ == "__main__":
    if not os.path.exists(LOCAL_MODEL_DIR):
        print(f"Error: Local model directory not found: {LOCAL_MODEL_DIR}")
        exit(1)

    official_metadata = get_official_file_metadata()
    if not official_metadata:
        print("Could not retrieve official metadata. Exiting.")
        exit(1)

    print("\nStarting local file validation process...")
    problematic_files = [] # [(filename, reason), ...]
    files_to_process = []

    # 收集所有需要校验的本地文件 (主要是 .safetensors 和重要的配置文件)
    for filename in official_metadata.keys(): # 以官方列表为准
        local_filepath = os.path.join(LOCAL_MODEL_DIR, filename)
        if os.path.exists(local_filepath):
            files_to_process.append((filename, local_filepath))
        else:
            if filename.endswith(".safetensors") or filename in ["config.json", "tokenizer.json", "model.safetensors.index.json"]:
                 print(f"  File MISSING locally: {filename}")
                 problematic_files.append((filename, "Missing locally"))

    if not files_to_process:
        print("No local files found to validate based on official metadata.")
        if problematic_files: # 如果有文件缺失
             if input("Some critical files are missing. Attempt to download the model? (y/n): ").lower() == 'y':
                attempt_redownload()
        exit()
        
    # 使用线程池并行计算本地文件哈希和大小
    # 注意：如果CPU核心不多或磁盘是瓶颈，并行效果可能不明显，甚至稍慢
    # 可以调整 max_workers 数量
    # 对于磁盘IO密集型任务，通常 workers 数量不宜远超 CPU 核心数
    num_workers = min(8, os.cpu_count() or 1) # 最多8个worker，或CPU核心数
    print(f"Using {num_workers} workers for local file hashing.")
    
    results = {}
    with ThreadPoolExecutor(max_workers=num_workers) as executor:
        future_to_file = {executor.submit(calculate_local_sha256_and_size, f_path): f_name for f_name, f_path in files_to_process}
        for i, future in enumerate(as_completed(future_to_file)):
            filename = future_to_file[future]
            try:
                local_sha256, local_size = future.result()
                results[filename] = (local_sha256, local_size)
                # 打印进度
                print(f"  Processed ({i+1}/{len(files_to_process)}): {filename} ")
            except Exception as exc:
                print(f"  Error processing {filename}: {exc}")
                results[filename] = ("error_processing", -3)


    # 开始校验
    print("\n--- Validation Results ---")
    for filename, (local_sha256, local_size) in results.items():
        print(f"\nValidating: {filename}")
        if filename not in official_metadata:
            print(f"  Warning: {filename} found locally but not in official metadata. Skipping.")
            continue

        official_info = official_metadata[filename]
        official_sha256 = official_info["sha256"]
        official_size = official_info["size"]

        print(f"  Official SHA256: {official_sha256}, Size: {official_size}")
        print(f"  Local    SHA256: {local_sha256}, Size: {local_size}")

        valid = True
        reason = []
        if local_sha256 is None: # 本地文件未找到 (理论上前面已处理，但双重检查)
            reason.append("Local file not found during hash calculation")
            valid = False
        elif local_sha256 == "error" or local_sha256 == "error_processing":
             reason.append("Error calculating local SHA256/Size")
             valid = False
        else:
            if local_size != official_size:
                reason.append(f"Size MISMATCH (local: {local_size}, official: {official_size})")
                valid = False
            if local_sha256 != official_sha256:
                reason.append(f"SHA256 MISMATCH") # 具体哈希值已打印，这里只标明不匹配
                valid = False
        
        if valid:
            print(f"  OK: {filename}")
        else:
            print(f"  ERROR: {filename} - {'; '.join(reason)}")
            problematic_files.append((filename, '; '.join(reason)))


    if problematic_files:
        print("\n--- Summary: Problematic Files ---")
        for f_name, reason_text in problematic_files:
            print(f"- {f_name}: {reason_text}")
        
        # 自动删除并重新下载的逻辑
        if input("\nDo you want to attempt to remove problematic files and re-download the entire model? (y/n): ").lower() == 'y':
            print("\nPreparing to remove problematic files (only those with SHA/Size mismatch, not 'Missing locally' if handled by snapshot_download)...")
            files_to_remove_for_redownload = []
            for f_name, reason_text in problematic_files:
                if "Missing locally" not in reason_text: # 如果是因为本地缺失，snapshot_download 会处理
                    local_filepath_to_remove = os.path.join(LOCAL_MODEL_DIR, f_name)
                    if os.path.exists(local_filepath_to_remove):
                        files_to_remove_for_redownload.append(local_filepath_to_remove)
            
            if files_to_remove_for_redownload:
                print("The following files will be REMOVED before attempting re-download:")
                for fp_rem in files_to_remove_for_redownload:
                    print(f"  - {fp_rem}")
                if input("Confirm removal? (y/n): ").lower() == 'y':
                    for fp_rem in files_to_remove_for_redownload:
                        try:
                            os.remove(fp_rem)
                            print(f"  Removed: {fp_rem}")
                        except OSError as e:
                            print(f"  Error removing {fp_rem}: {e}")
                    
                    attempt_redownload()
                    print("\nPlease run this validation script again after the re-download process completes.")
                else:
                    print("Removal cancelled. No files were deleted by this script.")
            elif any("Missing locally" in reason for _, reason in problematic_files):
                 print("Some files are missing. Attempting snapshot_download to fetch them...")
                 attempt_redownload()
                 print("\nPlease run this validation script again after the re-download process completes.")
            else:
                print("No files marked for removal (e.g. only missing files, or no problematic files).")

    else:
        print("\n--- Validation Summary: All checked files are VALID (SHA256 and size match official metadata)! ---")

    print("\nValidation process finished.")
