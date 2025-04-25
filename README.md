# vllmbash
适合vllm部署及测试的脚本
## nccltest
多卡必选。测试通过才行。


2.  **使用正确的 URL 重新下载：**
    ```bash
    wget https://raw.githubusercontent.com/tmzncty/vllmbash/main/nccltest.bash
    ```

3.  **（可选）检查文件内容：** 你可以用 `head nccltest.bash` 或 `cat nccltest.bash` 查看文件开头，确认它现在是 Bash 脚本代码而不是 HTML。

4.  **再次尝试执行：**
    ```bash
    bash nccltest.bash
    ```

这样应该就能正确执行脚本了（前提是脚本本身没有其他语法错误）。

## vllm_run_in_docker
在一些容器里面直接运行。
## vllm_run
在sudo的场景运行。
