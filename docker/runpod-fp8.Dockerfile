# syntax=docker/dockerfile:1
FROM vllm/vllm-openai:v0.30.0

LABEL org.opencontainers.image.source="https://github.com/ZhouDreams/llm-inference-lab"

COPY --from=model /layers-[0-9].safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model /layers-[1-2][0-9].safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model /layers-[3-4][0-9].safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model /layers-5[0-9].safetensors /layers-6[0-3].safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model /outside.safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model /mtp.safetensors /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=model \
    /LICENSE \
    /README.md \
    /chat_template.jinja \
    /config.json \
    /crc32.txt \
    /generation_config.json \
    /merges.txt \
    /model.safetensors.index.json \
    /preprocessor_config.json \
    /safetensors-md5sum.txt \
    /tokenizer.json \
    /tokenizer_config.json \
    /video_preprocessor_config.json \
    /vocab.json \
    /models/Qwen/Qwen3.8-27B-FP8/
COPY --from=app /runpod_auth.py /opt/runpod/runpod_auth.py

ENV HF_HUB_OFFLINE=1
ENV PYTHONPATH=/opt/runpod
