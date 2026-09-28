# AGENTS.md

## 概述

本项目是一个使用 vLLM 框架部署大语言模型的实验，目标是模拟企业级部署场景：

- **基础设施**：租用 AutoDL 的 GPU 服务器作为算力资源
- **环境管理**：使用 Docker / docker-compose 统一管理与部署 vLLM 服务
- **实验内容**：测试内存占用、并发性能等指标，评估生产环境部署方案

## 文件目录索引

| 主题 | 文件 /目录 | 备注 |
| --- | --- | --- |
| 项目说明 | [README.md](README.md) | - |
| 部署配置 | [docker-compose.yml](docker-compose.yml) | vLLM 容器编排；`VLLM_MODEL` 环境变量切换模型，默认 4-bit 量化版 |
| 模型清单 | [models/manifest.json](models/manifest.json) | 固定格式（manifestVersion 1），权重本身被 .gitignore 忽略 |
| 模型目录 | [models/](models/) | 按 `<org>/<name>` 存放下载的权重 |
| 脚本 | [scripts/](scripts/) | 服务启动（start.sh） |

## 模型下载（AutoDL / HuggingFace）

需要拉取模型权重时，直接使用 HuggingFace 官方 CLI：

1. 读 `models/manifest.json`，确定目标条目的 `id`（`org/name` 形式）；`start.sh` 只认 `enabled` 条目
2. 准备网络（二选一）：`source /etc/network_turbo`（AutoDL 学术加速，直连 huggingface.co）或 `export HF_ENDPOINT=https://hf-mirror.com`（镜像）
3. 确保 CLI 可用：`pip install -U "huggingface_hub[cli]"`（新版命令名为 `hf download`，用法一致）
4. 下载（`--local-dir` 路径必须与 id 严格对应，`start.sh` 按此布局解析权重）：

   ```bash
   huggingface-cli download <org>/<name> --local-dir models/<org>/<name>
   ```

5. 校验落盘：目录内应有 `config.json` 与 `.safetensors` 分片
6. 若开了学术加速，用完执行 `unset http_proxy https_proxy` 关闭

注意：

- 下载中断直接重跑同一命令即可续传，不要手动清理下载目录下的 `.cache`
- 受限仓库需先 `export HF_TOKEN=<token>`
- 容器以 `HF_HUB_OFFLINE=1` 运行，vLLM 不会自行联网拉模型：权重必须先落盘到 `models/`，否则 `start.sh` 会报错退出