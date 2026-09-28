# llm-inference-lab

使用 vLLM 部署大语言模型的实验项目，目标是模拟企业级部署场景：

- **基础设施**：租用 AutoDL 的 GPU 服务器作为算力资源
- **环境管理**：使用 Docker / docker-compose 统一管理与部署 vLLM 服务
- **实验内容**：测试内存占用、并发性能等指标，评估生产环境部署方案

## 测试模型

| 模型 | 说明 |
| --- | --- |
| [cyankiwi/Qwen3.8-27B-AWQ-INT4](https://huggingface.co/cyankiwi/Qwen3.8-27B-AWQ-INT4) | 4-bit AWQ 量化版（compressed-tensors），约 19.6 GiB，单张 24G 显卡可跑，主力测试对象 |
| [Qwen/Qwen3.8-27B-FP8](https://huggingface.co/Qwen/Qwen3.8-27B-FP8) | 官方 FP8 量化版，精度损失最小的量化档 |
| [Qwen/Qwen3.8-27B](https://huggingface.co/Qwen/Qwen3.8-27B) | 官方全量 BF16 原版，约 51.8 GiB，对照组 |

两个模型架构均为 `Qwen3_5ForConditionalGeneration`，已在 vLLM v0.30.0 支持列表中核实。

## docker-compose

`docker-compose.yml` 定义单个 `vllm` 服务（镜像钉在 `vllm/vllm-openai:v0.30.0`）：

| 配置 | 值 | 说明 |
| --- | --- | --- |
| 端口 | `127.0.0.1:8000:8000` | 只绑本机回环，经 ssh 隧道访问（见下文） |
| 挂载 | `./models:/models:ro` | 权重目录只读挂载 |
| GPU | `deploy.resources.reservations.devices` | NVIDIA 运行时透传全部显卡 |
| 健康检查 | `GET /health` | `start_period: 10m` 容纳权重加载耗时 |
| `ipc` | `host` | vLLM 官方推荐，多进程共享内存通信 |
| `HF_HUB_OFFLINE` | `1` | 权重已本地化，禁止隐式联网拉模型 |

模型路径通过环境变量注入：`VLLM_MODEL` 指定权重路径（默认 4-bit 版），`VLLM_EXTRA_ARGS` 透传任意 vLLM 参数（由 `start.sh` 设置，也可手动 export）。

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

使用 HuggingFace 官方 CLI 按 [manifest](models/manifest.json) 中的仓库 id 下载权重，落位 `models/<org>/<name>/`。

### AutoDL 网络环境

AutoDL 服务器在国内，访问 HuggingFace 二选一：

```bash
source /etc/network_turbo                    # 方式一：AutoDL 学术加速，直连 huggingface.co
export HF_ENDPOINT=https://hf-mirror.com     # 方式二：走 hf-mirror.com 镜像
```

学术加速是临时代理，用完记得关闭，避免影响其他流量：`unset http_proxy https_proxy`。

### 下载命令

```bash
pip install -U "huggingface_hub[cli]"

huggingface-cli download cyankiwi/Qwen3.8-27B-AWQ-INT4 \
  --local-dir models/cyankiwi/Qwen3.8-27B-AWQ-INT4
```

- `--local-dir` 必须是 `models/<org>/<name>`（与 manifest 的 id 对应），`start.sh` 按这个布局找权重
- 新版 CLI 命令名为 `hf download <repo> --local-dir ...`，用法一致
- 中断可续传：重跑同一命令自动续传
- 受限仓库：先 `huggingface-cli login`，或 `export HF_TOKEN=<token>`
- 下载完抽查目录：应包含 `config.json` 与 `.safetensors` 分片

其余模型同理，例如切全量对照版前先下载：

```bash
huggingface-cli download Qwen/Qwen3.8-27B --local-dir models/Qwen/Qwen3.8-27B
```

## 脚本

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

## 上服务器（AutoDL）流程

```bash
# 1. 拉代码到服务器，进入项目目录
source /etc/network_turbo                            # 2. 开学术加速（下载权重、拉镜像都走它）
pip install -U "huggingface_hub[cli]"
huggingface-cli download cyankiwi/Qwen3.8-27B-AWQ-INT4 \
  --local-dir models/cyankiwi/Qwen3.8-27B-AWQ-INT4
./scripts/start.sh                                    # 3. 启动（首次拉 vLLM 镜像约 10 GB）
docker compose ps                                    # 等待 (healthy)
unset http_proxy https_proxy                          # 4. 关闭学术加速
ssh -L 8000:localhost:8000 root@<autodl主机>          # 5. 本地经隧道访问，请求 localhost:8000
```

切全量版对照：`./scripts/start.sh -m Qwen/Qwen3.8-27B`
