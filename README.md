# vllmbash
适合vllm部署及测试的脚本
## nccltest
多卡必选。测试通过才行。


1.  **使用正确的 URL 重新下载：**
    ```bash
    wget https://raw.githubusercontent.com/tmzncty/vllmbash/main/nccltest.bash
    ```

2.  **（可选）检查文件内容：** 你可以用 `head nccltest.bash` 或 `cat nccltest.bash` 查看文件开头，确认它现在是 Bash 脚本代码而不是 HTML。

3.  **再次尝试执行：**
    ```bash
    bash nccltest.bash
    ```

这样应该就能正确执行脚本了（前提是脚本本身没有其他语法错误）。

## vllm_run_in_docker
在一些容器里面直接运行。


正确的下载命令应该是：
```bash
wget https://raw.githubusercontent.com/tmzncty/vllmbash/main/vllm_in_docker.sh
```


```bash
bash vllm_in_docker.sh
```
**总结一下规律：**
* 从 GitHub 下载文件供程序（如 `bash`）使用时，要确保 URL 指向的是 **raw** 内容。
* 网页链接通常包含 `/blob/`。
* Raw 链接通常在 `raw.githubusercontent.com` 这个域名下，并且路径中没有 `/blob/`。
## vllm_run
在sudo的场景运行。
