# 集成测试环境：与脚本的目标环境一致（Debian + apt + 系统 nginx）。
# 单测只能覆盖纯函数；渲染管线、回滚、nginx -t、并发锁这些必须有真 nginx 才测得到。
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        nginx \
        openssl \
        ca-certificates \
        procps \
        util-linux \
        iproute2 \
        mawk \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /work
COPY . /work

CMD ["bash", "tests/integration/run.sh"]
