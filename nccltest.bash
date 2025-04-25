#!/bin/bash

# Bash脚本：自动克隆、编译并运行NCCL all_reduce_perf测试 (v2 - 修复GPU计数问题)

# 脚本出错时立即退出
set -e

# --- 配置 ---
REPO_URL="https://gitee.com/devilmaycry812839668/nccl-tests.git"
REPO_DIR="nccl-tests"
# NCCL测试编译后的可执行文件路径 (通常是这个)
TEST_BINARY="build/all_reduce_perf"
# 你指定的测试参数
TEST_PARAMS="-b 1 -e 2M -f 2"

# --- 功能函数 ---
log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
    exit 1
}

# --- 主脚本逻辑 ---

log_info "开始执行 NCCL 测试脚本 (v2)..."

# 1. 检查依赖: git 和 nvidia-smi
log_info "检查依赖项 (git, nvidia-smi)..."
if ! command -v git &> /dev/null; then
    log_error "未找到 'git' 命令。请先安装 Git。"
fi
if ! command -v nvidia-smi &> /dev/null; then
    log_error "未找到 'nvidia-smi' 命令。请确保已正确安装 NVIDIA 驱动程序。"
fi
log_info "依赖项检查通过。"

# 2. 克隆仓库 (如果目录不存在)
if [ ! -d "$REPO_DIR" ]; then
    log_info "目录 '$REPO_DIR' 不存在，正在从 $REPO_URL 克隆..."
    git clone "$REPO_URL" "$REPO_DIR"
    log_info "仓库克隆完成。"
else
    log_info "目录 '$REPO_DIR' 已存在，跳过克隆步骤。"
fi

# 3. 进入仓库目录
log_info "进入目录 '$REPO_DIR'..."
cd "$REPO_DIR" || log_error "无法进入目录 '$REPO_DIR'。"
log_info "当前工作目录: $(pwd)"

# 4. 编译 NCCL 测试
if [ ! -f "$TEST_BINARY" ]; then
    log_info "目标测试文件 '$TEST_BINARY' 不存在，开始编译 (这可能需要一些时间)..."
    log_info "执行 make clean..."
    make clean > /dev/null 2>&1
    log_info "执行 make -j $(nproc)..."
    make -j $(nproc)
    log_info "编译完成。"
else
    log_info "目标测试文件 '$TEST_BINARY' 已存在，跳过编译步骤。"
fi

# 检查编译产物是否存在
if [ ! -f "$TEST_BINARY" ]; then
    log_error "编译后未找到测试文件 '$TEST_BINARY'。请检查编译过程是否有错误。"
fi

# 5. 自动检测 GPU 数量
log_info "正在检测 NVIDIA GPU 数量..."
# 使用 nvidia-smi 查询 GPU 数量, 并用 head -n 1 取第一行防止重复输出
GPU_COUNT=$(nvidia-smi --query-gpu=count --format=csv,noheader | head -n 1)

# 验证获取到的 GPU 数量是否为有效数字
if ! [[ "$GPU_COUNT" =~ ^[0-9]+$ ]]; then
     # 在错误信息中显示原始获取的值，便于调试
     RAW_OUTPUT=$(nvidia-smi --query-gpu=count --format=csv,noheader)
     log_error "无法从 nvidia-smi 获取有效的 GPU 数量。原始输出: '$RAW_OUTPUT' 处理后: '$GPU_COUNT'"
fi

if [ "$GPU_COUNT" -eq 0 ]; then
    log_error "nvidia-smi 检测到 0 个 GPU。无法运行 NCCL 测试。"
fi
log_info "检测到 $GPU_COUNT 个 GPU。"

# 6. 运行 all_reduce_perf 测试
log_info "准备运行 all_reduce_perf 测试..."
COMMAND="./$TEST_BINARY $TEST_PARAMS -g $GPU_COUNT"
log_info "执行命令: $COMMAND"
echo "---------------------- NCCL Test Output Start ----------------------"

# 执行测试命令
$COMMAND

# 检查上一个命令的退出状态码
if [ $? -ne 0 ]; then
    echo "----------------------- NCCL Test Output End -----------------------"
    log_error "NCCL 测试命令执行失败。"
else
    echo "----------------------- NCCL Test Output End -----------------------"
    log_info "NCCL all_reduce_perf 测试成功完成！"
fi

# 7. 返回到之前的目录 (可选)
cd ..
log_info "脚本执行完毕。"

exit 0
