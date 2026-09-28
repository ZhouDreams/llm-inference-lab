# AGENTS.md

## 概述

本项目是一个使用 vLLM 框架部署大语言模型的实验，目标是模拟企业级部署场景：

- **基础设施**：租用云 GPU 服务器作为算力资源
- **部署路线**：三条并行——AutoDL 容器上的原生部署、RunPod 上的模板部署（平台代跑容器）、裸金属上的 docker-compose 部署
- **实验内容**：测试内存占用、并发性能等指标，评估生产环境部署方案

## 文件目录索引

| 主题 | 文件 /目录 | 备注 |
| --- | --- | --- |
| 项目说明 | [README.md](README.md) | - |
| Docker 路线部署配置 | [docker-compose.yml](docker-compose.yml) | vLLM 容器编排；`VLLM_MODEL` 环境变量切换模型，默认 4-bit 量化版 |
| 模型清单 | [models/manifest.json](models/manifest.json) | 固定格式（manifestVersion 1），权重本身被 .gitignore 忽略 |
| 模型目录 | [models/](models/) | 按 `<org>/<name>` 存放下载的权重，各路线共用 |
| 脚本 | [scripts/](scripts/) | Docker 路线服务启动（start.sh） |

## 部署路线选择

- **AutoDL 容器实例** → 原生路线。AutoDL 官方明确容器内不支持 Docker（无 `SYS_ADMIN` / `NET_ADMIN`，命名空间创建被内核拒绝），任何依赖容器化 / iptables 的组件均不可用
- **RunPod Pod** → 模板路线。平台代跑容器（镜像由模板指定），Pod 内不能自建 Docker daemon、不支持 docker compose；海外网络直连
- **裸金属 / 任意支持 Docker 的宿主** → Docker 路线（docker-compose + nvidia-container-toolkit）

三条路线共用同一份 manifest 与 `models/<org>/<name>` 权重布局；RunPod 路线上 AWQ 权重位于 Network Volume 的 `/workspace/models/`，FP8 权重打包进镜像 `/models/`（见 RunPod 章节）。

## 模型下载（路线通用）

需要拉取模型权重时，直接使用 HuggingFace 官方 CLI：

1. 读 `models/manifest.json`，确定目标条目的 `id`（`org/name` 形式）
2. 确保 CLI 可用：`pip install -U "huggingface_hub[cli]"`（新版命令名为 `hf download`，用法一致）
3. 下载（`--local-dir` 路径必须与 id 严格对应，各路线都按此布局解析权重）：

   ```bash
   huggingface-cli download <org>/<name> --local-dir models/<org>/<name>
   ```

4. 校验落盘：目录内应有 `config.json` 与 `.safetensors` 分片
5. 网络受限环境按所属路线章节的通道说明执行（AutoDL 见下；RunPod 与可直连环境无需配置）

下载中断直接重跑同一命令即可续传，不要手动清理下载目录下的 `.cache`；受限仓库需先 `export HF_TOKEN=<token>`。

## 原生路线（AutoDL）

- **网络通道**：GitHub / Docker Hub 直连不可用，公共代理同样不可用；部分区域无学术加速（`source /etc/network_turbo` 会提示不支持），可靠通道为 hf-mirror（pip 走镜像自带阿里云源）
- **模型下载必须禁用 Xet**：`export HF_ENDPOINT=https://hf-mirror.com HF_HUB_DISABLE_XET=1`——Xet 传输协议直连 hf.co 不走镜像，会报 401
- **代码同步**：服务器上 GitHub 不可达时，由本机 `git push` 到服务器端裸仓库，服务器上再 `git pull`
- **环境安装**：`pip install vllm==0.30.0`（与 Docker 路线镜像钉的版本一致）
- **启动**：无 systemd，用 `nohup vllm serve models/<org>/<name> --served-model-name qwen3.8-27b --host 127.0.0.1 --port 8000 --gpu-memory-utilization 0.90 > vllm.log 2>&1 &` 后台拉起；关机后进程不保留，重新开机需重新拉起
- **验证**：`curl http://127.0.0.1:8000/health`；本地经 `ssh -L 8000:localhost:8000` 隧道访问
- **磁盘预算**：数据盘 50G 时 AWQ-INT4（19.6 GiB）可放，FP8（28.8 GiB）与 AWQ 二选一，BF16（51.8 GiB）需扩容

## RunPod 模板路线

- **机制**：Pod 即平台托管的容器，镜像由模板指定、平台运行；Pod 内不能自建 Docker / compose；GPU 由 Pod 规格决定，平台已注入运行时
- **网络**：海外直连，GitHub / HuggingFace / Docker Hub 无需任何加速
- **访问与验证**：代理 URL `https://<pod-id>-8000.proxy.runpod.net`（控制台 Connect 页给出），`curl <代理URL>/health` 验证；也可 SSH 隧道访问

两条子路线，权重放置方式不同：

### AWQ：权重置于 Network Volume

- 挂 Network Volume（默认挂 `/workspace`，跨关机持久，仅 Secure Cloud 提供；Pod 根磁盘停止后清空），SSH 进 Pod 下载到 `/workspace/models/cyankiwi/Qwen3.8-27B-AWQ-INT4`（SSH 命令在 Pod 的 Connect 页，公钥在账号设置）
- 镜像 `vllm/vllm-openai:v0.30.0`；暴露 HTTP 端口 `8000`；环境变量 `HF_HUB_OFFLINE=1`
- 容器参数与 Docker 路线 compose 的 command 一致，但 `--host 0.0.0.0`（RunPod 经代理转发流量，容器需监听非回环地址）

### FP8：模型内置镜像

- 权重由 `docker/runpod-fp8.Dockerfile` 打包到镜像内 `/models/Qwen/Qwen3.8-27B-FP8`，不依赖 `/workspace` 挂载；镜像基于 `vllm/vllm-openai:v0.30.0` 构建，推送至 GHCR：`ghcr.io/zhoudreams/llm-inference-lab-vllm:fp8`（构建命令见 README）
- 镜像解压后约 34 GB，Container disk 配 60 GB；公开镜像 RunPod 可匿名拉取
- 暴露 HTTP 端口 `8000`；镜像内置 `HF_HUB_OFFLINE=1`；`VLLM_API_KEY` 通过 RunPod Secret 注入
- 启动参数含 `--middleware runpod_auth.require_key`（定义于 `docker/runpod_auth.py`）：除 `/health` 外的请求须携带 `Authorization: Bearer <VLLM_API_KEY>`，未配置密钥时推理返回 503；完整参数见 README
- 当前生产实例：Pod `static_coffee_wallaby`（EU-RO-1，A100 80GB），详细参数以 README 为准

## Docker 路线（裸金属）

- **前置**：docker + compose v2 + nvidia-container-toolkit（GPU 透传）
- **权重**：先按「模型下载」落位 `./models/<org>/<name>`
- **启动**：`./scripts/start.sh`——从 manifest 解析模型路径，`-m` 关键词选模型（不区分大小写包含匹配，多候选时收窄），其余参数原样透传给 vLLM；模型未下载时报错并给出下载命令
- **验证**：`docker compose ps` 等待 `(healthy)`；容器以 `HF_HUB_OFFLINE=1` 运行，vLLM 不会自行联网拉模型，权重必须先落盘
