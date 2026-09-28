# llm-inference-lab

使用 vLLM 部署大语言模型的实验项目，目标是模拟企业级部署场景：

- **基础设施**：租用云 GPU 服务器作为算力资源
- **部署路线**：三条并行——AutoDL 容器上的**原生部署**、RunPod 上的**模板部署**（平台代跑容器）、裸金属上的 **Docker compose 部署**
- **实验内容**：测试内存占用、并发性能等指标，评估生产环境部署方案

## 测试模型

| 模型 | 说明 |
| --- | --- |
| [cyankiwi/Qwen3.8-27B-AWQ-INT4](https://huggingface.co/cyankiwi/Qwen3.8-27B-AWQ-INT4) | 4-bit AWQ 量化版（compressed-tensors），约 19.6 GiB，单张 24G 显卡可跑，主力测试对象 |
| [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8) | 官方 FP8 量化版，精度损失最小的量化档 |
| [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | 官方全量 BF16 原版，约 51.8 GiB，对照组 |

三个模型架构均为 `Qwen3_5ForConditionalGeneration`，已在 vLLM v0.30.0 支持列表中核实。

## manifest 格式

`models/manifest.json` 是模型清单的唯一事实来源，`start.sh` 按它解析模型路径、不写死任何模型；下载权重时也以其中的仓库 id 为准。权重文件本身被 `.gitignore` 忽略，只保留 manifest 入库。

```json
{
  "manifestVersion": 1,
  "models": [
    {
      "id": "org/name",          // 必填，Hugging Face 仓库 ID
      "revision": "main",        // 可选，默认 main
      "enabled": true,           // 可选，默认 true
      "note": "备注"             // 可选
    }
  ]
}
```

## 模型下载

使用 HuggingFace 官方 CLI 按 [manifest](models/manifest.json) 中的仓库 id 下载权重，落位 `models/<org>/<name>/`（RunPod 上为 `/workspace/models/<org>/<name>`），各部署路线共用此布局。

```bash
pip install -U "huggingface_hub[cli]"

huggingface-cli download cyankiwi/Qwen3.8-27B-AWQ-INT4 \
  --local-dir models/cyankiwi/Qwen3.8-27B-AWQ-INT4
```

- `--local-dir` 必须与 manifest 的 id 严格对应，各路线的启动环节都按这个布局找权重
- 新版 CLI 命令名为 `hf download <repo> --local-dir ...`，用法一致
- 中断可续传：重跑同一命令自动续传
- 受限仓库：先 `huggingface-cli login`，或 `export HF_TOKEN=<token>`
- 下载完抽查目录：应包含 `config.json` 与 `.safetensors` 分片
- 国内受限网络按「原生部署（AutoDL）」章节配置通道；RunPod 与可直连环境无需任何额外设置

其余模型同理，例如切全量对照版前先下载：

```bash
huggingface-cli download Qwen/Qwen3.8-27B --local-dir models/Qwen/Qwen3.8-27B
```

## 原生部署（AutoDL）

不经过 Docker，直接在 AutoDL 实例上运行 vLLM。

### 网络通道

- 部分区域支持学术加速：`source /etc/network_turbo`，用完关闭 `unset http_proxy https_proxy`；nma1 等区域不支持
- 可靠通道是 hf-mirror 镜像，且**必须同时禁用 Xet 传输**（Xet 的 CAS 协议直连 hf.co 不走镜像，会报 401）：

  ```bash
  export HF_ENDPOINT=https://hf-mirror.com HF_HUB_DISABLE_XET=1
  ```

- pip 走镜像自带的阿里云源；GitHub 与 Docker Hub 直连不可用

### 容器限制

- AutoDL 官方明确：容器实例内不支持使用 Docker（需要 Docker 请租用裸金属服务器，整机包月起租）；容器无 `SYS_ADMIN` / `NET_ADMIN`，命名空间创建被内核拒绝，所以 AutoDL 上走原生部署
- 无 systemd：进程用 `nohup` 拉起，实例关机后进程不保留，重新开机需重新拉起（数据盘上的权重与代码不受影响）

### 磁盘预算（以 50G 数据盘 `/root/autodl-tmp` 为例）

| 模型 | 大小 | 80G 显存 | 50G 数据盘 |
|------|------|---------|-----------|
| AWQ-INT4 | 19.6 GiB | ✅ | ✅ |
| FP8 | 28.8 GiB | ✅（Marlin 仿真，无 native FP8） | ⚠️ 与 AWQ 二选一 |
| BF16 全量 | 51.8 GiB | ✅ | ❌ 放不下，需扩容 |

### 代码上服务器

GitHub 不可达时，可从本机直接推送到服务器端裸仓库，再在服务器上检出：

```bash
# 本机
git push ssh://root@<host>:<port>/root/autodl-tmp/llm-inference-lab.git main:main
# 服务器
git clone /root/autodl-tmp/llm-inference-lab.git && cd llm-inference-lab && git pull
```

### 安装与启动

```bash
pip install vllm==0.30.0        # 与 Docker 路线镜像钉的版本一致

cd <项目目录>
nohup vllm serve models/cyankiwi/Qwen3.8-27B-AWQ-INT4 \
  --served-model-name qwen3.8-27b \
  --host 127.0.0.1 --port 8000 \
  --gpu-memory-utilization 0.90 \
  > vllm.log 2>&1 &
```

- 核心参数与 docker-compose 中一致：`--served-model-name` 服务别名、`--gpu-memory-utilization` 显存占比；其余 vLLM 参数按需追加
- 绑定 `127.0.0.1`，本地经隧道访问：`ssh -L 8000:localhost:8000 root@<autodl主机>`，然后请求 `localhost:8000`
- 健康检查：`curl http://127.0.0.1:8000/health`；首次加载 27B 权重需数分钟，进度看 `vllm.log`

### 端到端流程（从零到服务可用）

1. 代码上服务器（见上）
2. 配置网络通道，按「模型下载」下载权重
3. 安装 vLLM 并按上述命令启动
4. 本地 ssh 隧道访问

切全量版对照：重新启动服务时把模型路径换成 `models/Qwen/Qwen3.8-27B`（需先下载，且数据盘容量允许）。

## RunPod 模板部署

RunPod 的 Pod 本身就是平台托管的容器：镜像由你指定、由平台运行；Pod 内不能自建 Docker daemon，也不支持 docker compose（官方文档 Limitations 明示）。平台在海外，GitHub / HuggingFace / Docker Hub 全部直连，无需任何加速通道。

### 权重准备

创建 Pod 时挂载 Network Volume（默认挂载到 `/workspace`，跨关机持久；仅 Secure Cloud 提供），SSH 进 Pod 下载权重（SSH 命令在 Pod 的 Connect 页面，公钥在账号设置中配置）：

```bash
pip install -U "huggingface_hub[cli]"
huggingface-cli download cyankiwi/Qwen3.8-27B-AWQ-INT4 \
  --local-dir /workspace/models/cyankiwi/Qwen3.8-27B-AWQ-INT4
```

Pod 根磁盘在关机后清空，权重与代码一律放 Network Volume。

### Pod / 模板配置（Custom Template）

| 项 | 值 |
| --- | --- |
| 镜像 | `vllm/vllm-openai:v0.30.0` |
| 暴露端口 | HTTP `8000` |
| 环境变量 | `HF_HUB_OFFLINE=1` |
| 容器参数 | `--model /workspace/models/cyankiwi/Qwen3.8-27B-AWQ-INT4 --served-model-name qwen3.8-27b --host 0.0.0.0 --port 8000 --gpu-memory-utilization 0.90` |

- 容器参数与 docker-compose 的 command 一致；`--host 0.0.0.0` 与裸机路线不同——RunPod 经代理转发流量，容器需监听非回环地址
- GPU 数量在 Pod 规格中选择，平台已注入 GPU 运行时，无需任何 nvidia 配置

### 访问与验证

服务地址为控制台 Connect 页给出的代理 URL（形如 `https://<pod-id>-8000.proxy.runpod.net`）：

```bash
curl https://<pod-id>-8000.proxy.runpod.net/health
```

也可经 SSH 隧道访问。磁盘预算同样参照「测试模型」表中的模型大小规划 Network Volume 容量。

## Docker 部署（裸金属）

### docker-compose

`docker-compose.yml` 定义单个 `vllm` 服务（镜像钉在 `vllm/vllm-openai:v0.30.0`）：

| 配置 | 值 | 说明 |
| --- | --- | --- |
| 端口 | `127.0.0.1:8000` | 使用主机网络，只监听本机回环，经 ssh 隧道访问（见下文） |
| 挂载 | `./models:/models:ro` | 权重目录只读挂载 |
| GPU | `deploy.resources.reservations.devices` | NVIDIA 运行时透传全部显卡 |
| 健康检查 | `GET /health` | `start_period: 10m` 容纳权重加载耗时 |
| `ipc` | `host` | vLLM 官方推荐，多进程共享内存通信 |
| `HF_HUB_OFFLINE` | `1` | 权重已本地化，禁止隐式联网拉模型 |

模型路径通过环境变量注入：`VLLM_MODEL` 指定权重路径（默认 4-bit 版），`VLLM_EXTRA_ARGS` 透传任意 vLLM 参数（由 `start.sh` 设置，也可手动 export）。启动前权重先按「模型下载」落位 `./models/`。

### 脚本

[scripts/start.sh](scripts/start.sh)：启动 vLLM 服务的薄包装（`docker compose up -d`），从 manifest 解析模型路径，不写死模型，零第三方依赖。

```bash
./scripts/start.sh                                    # 默认：manifest 第一个 enabled 模型
./scripts/start.sh -m awq                             # 模型关键词（对 manifest 里 id 做包含匹配）
./scripts/start.sh -m Qwen/Qwen3.8-27B                # 也可以传完整 id
./scripts/start.sh -m awq --max-model-len 8192        # 透传 vLLM 参数
```

行为：

- `-m` / `--model` 的值用于在 manifest 中匹配（不区分大小写、包含匹配）；匹配到多个会列出候选要求收窄；模型未下载时报错并给出对应下载命令
- `--max-model-len`、`--gpu-memory-utilization` 等其余参数原样透传给 vLLM
- 不传 `--max-model-len` 时使用模型原生上下文长度

启动后 `docker compose ps` 等待 `(healthy)`，本地经 `ssh -L 8000:localhost:8000 <user>@<host>` 隧道访问 `localhost:8000`。
