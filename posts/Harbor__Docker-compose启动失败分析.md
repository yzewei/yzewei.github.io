# Harbor::Docker-compose启动失败分析

## 01 问题描述

在使用 docker-compose 部署 Harbor 时遇到一个现象：服务有时候能正常启动，有时候启动失败。

问题日志：

```shellscript
ddb266c70e76 cr.loongnix.cn/harbor/harbor-jobservice:2.2.1 "/harbor/entrypoint.…" 48 seconds ago Up 38 seconds (health: starting) harbor-jobservice
89109fe1dcb0 cr.loongnix.cn/harbor/nginx-photon:2.2.1 "nginx -g 'daemon of…" 48 seconds ago Restarting (1) 13 seconds ago nginx
b965a3ab3f9c cr.loongnix.cn/harbor/harbor-core:2.2.1 "/harbor/entrypoint.…" 50 seconds ago Restarting (1) 1 second ago harbor-core
7c3a830b2821 cr.loongnix.cn/harbor/harbor-db:2.2.1 "/docker-entrypoint.…" 52 seconds ago Up 43 seconds (healthy) harbor-db
59b80ec6e264 cr.loongnix.cn/harbor/harbor-portal:2.2.1 "nginx -g 'daemon of…" 52 seconds ago Up 43 seconds (healthy) harbor-portal
5eed18a72884 cr.loongnix.cn/harbor/harbor-registryctl:2.2.1 "/home/harbor/start.…" 52 seconds ago Up 43 seconds (healthy) registryctl
8292f0b126d8 cr.loongnix.cn/harbor/registry-photon:2.2.1 "/home/harbor/entryp…" 52 seconds ago Up 43 seconds (healthy) registry
8d75abeadfda cr.loongnix.cn/harbor/redis-photon:2.2.1 "redis-server /etc/r…" 52 seconds ago Up 41 seconds (healthy) redis
09d15838f356 cr.loongnix.cn/harbor/harbor-log:2.2.1 "/bin/sh -c /usr/loc…" 53 seconds ago Up 45 seconds (healthy) 127.0.0.1:1514->10514/tcp harbor-log
```

通过分析启动过程发现，该问题与 Docker 容器的健康检查机制以及 docker-compose 的 `depends_on`依赖管理机制有关。基于此现象，我们提出以下几个具体问题：

1. 什么是容器的健康检查？为什么需要健康检查？
2. 如何构建一个支持健康状态检测的Docker镜像？
3. 在使用`docker-compose up -d`命令时，为什么会出现`depends_on`依赖关系看似未生效的情况？

***

## 02 机理分析

### 2.1 什么是容器的健康检查？为什么需要健康检查？

容器的健康检查（Health Check）是用来检测容器内运行的应用是否处于健康状态的一种机制。它可以帮助你自动发现和处理异常状态的服务，确保系统更加稳定和可靠。

容器可能仍在运行，但里面的应用已经崩溃或卡死了。健康检查可以：

* 自动识别失败的应用实例
* 触发重启或替换不健康的容器
* 与编排工具（如 Kubernetes、Docker Swarm）集成，实现自愈能力

***

### 2.2 如何构建一个支持健康状态检测的Docker镜像？

Docker 的 `HEALTHCHECK` 指令允许你指定一个命令，用于检测容器内部应用是否健康运行。当命令执行成功（退出码为 0）时，容器状态为 healthy，否则为 unhealthy。如果要为 Docker 镜像添加健康检查，则需要在 Dockerfile 中使用 `HEALTHCHECK` 指令:

```docker
FROM cr.loongnix.cn/library/python:3.10.14-slim-buster

WORKDIR /app

RUN pip install --no-cache-dir flask

COPY app.py .

# 添加健康检查：尝试访问 /health
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:5000/health || exit 1
CMD ["python", "app.py"]
```

\- `app.py`

```python
import time
from flask import Flask, jsonify

app = Flask(__name__)

@app.route("/")
def index():
    return "Hello, World!"

@app.route("/health")
def health():
    return jsonify(status="ok"), 200

if __name__ == "__main__":
    time.sleep(20)
    app.run(host="0.0.0.0", port=5000)
```

* &#x20;`--interval=10s`：Docker 每隔 10 秒 执行一次健康检查命令。
* `--timeout=3s`: 如果 curl 命令在 3 秒内没有完成，则这次健康检查视为失败。
* &#x20;`--start-period=5s`: Docker 会等待容器启动 5 秒钟 后，才开始执行第一次健康检查。在这 5 秒内的失败不会计入重试次数。
* &#x20;`--retries=3`：如果连续 3 次 健康检查都失败，Docker 就会把容器状态设为 unhealthy。

***



* &#x20;构建命令： `docker build -t flask-health .`
* &#x20;启动命令： `docker run -d -p 5000:5000 --name flask_app flask-health`

启动过程日志：

```shellscript
## 刚启动(health: starting)
CONTAINER ID   IMAGE                                            COMMAND                  CREATED          STATUS                            PORTS                                                                           NAMES
193c5b0b3106   flask-health                                     "python app.py"          10 seconds ago   Up 8 seconds (health: starting)   0.0.0.0:5000->5000/tcp 

## 一段时间后(healthy)
CONTAINER ID   IMAGE                                            COMMAND                  CREATED          STATUS                    PORTS                                                                           NAMES193c5b0b3106   flask-health                                     "python app.py"          13 seconds ago   Up 11 seconds (healthy)   0.0.0.0:5000->5000/tcp                                                          flask_app
```

***

### 2.3 在使用`docker-compose up -d`命令时，为什么会出现`depends_on`依赖关系看似未生效的情况？

* `depends_on` 的真正作用: `depends_on` 只控制容器的启动顺序，不保证被依赖服务就绪可用。

***

`depends_on` 作用验证：

```docker
FROM cr.loongnix.cn/library/debian:buster

RUN apt update && apt install curl -y

ENV TARGET_URL=http://flask_app:5000/health

CMD if curl --connect-timeout 3 --max-time 3 -fsS "$TARGET_URL"; then \
      echo "Health check succeeded! Container will stay alive."; \
      tail -f /dev/null; \
    else \
      echo "Health check FAILED. Exiting."; \
      exit 1; \
    fi
```

* &#x20;功能：该镜像在启动后会检测 flask\_app 镜像的可用性。若 flask\_app 服务正常响应，则容器继续运行；否则容器将自动终止。
* &#x20;构建命令： `docker build -t health-probe .`

\- `docker-compose.yml`

```yaml
version: "2.10"

services:
  flask_app:
    image: flask-health
    ports:
      - "5000:5000"

  probe:
    image: health-probe
    depends_on:
    - flask_app
```

输出日志：

```shellscript
## `flask-health` 没有进入healthy `health-probe` 启动
CONTAINER ID   IMAGE                                            COMMAND                  CREATED         STATUS                           PORTS                                                                           NAMES
a892e098fe9f   health-probe                                     "/bin/sh -c 'if curl…"   4 seconds ago   Up Less than a second                                                                                            test-probe-1
9f86b9828cde   flask-health                                     "python app.py"          5 seconds ago   Up 1 second (health: starting)   0.0.0.0:5000->5000/tcp                                                          test-flask_app-1

## probe 服务日志
curl: (7) Failed to connect to flask_app port 5000: Connection refusedHealth check FAILED. Exiting.
```

***

### 2.4 什么是 `depends_on.condition: service_healthy` ?

`depends_on.condition: service_healthy`是 Docker Compose 的一个配置选项，用于指定一个服务（Service）只有在另一个服务​​健康状态正常​​时才会启动。它通常与 `healthcheck`配置一起使用。

​​**核心作用​**:​

* 控制启动顺序​​确保服务 A 只有在服务 B ​​完全就绪​​（而不仅仅是容器启动）后才会启动。
* 依赖健康状态​​不单纯依赖容器是否运行，而是检查目标服务是否通过健康检查（如数据库完成初始化、Web 服务能响应 HTTP 请求等）。
* 避免竞态条件​​防止因依赖服务未准备好而导致的连接失败或启动错误（例如应用在数据库初始化完成前尝试连接）。

具体修改

```diff
<     - flask_app
---
>       flask_app:
>         condition: service_healthy 
```

启动日志：

```shellscript
## 1. `flask-health` 进入healthy之前 `health-probe` 是不会启动的
CONTAINER ID   IMAGE                                            COMMAND                  CREATED          STATUS                             PORTS                                                                           NAMES
7ba743998c8a   flask-health                                     "python app.py"          19 seconds ago   Up 15 seconds (health: starting)   0.0.0.0:5000->5000/tcp 


## 2. `flask-health` 进入healthy状态 `health-probe` 启动
CONTAINER ID   IMAGE                                            COMMAND                  CREATED          STATUS                    PORTS                                                                           NAMES
ceb9071ac270   health-probe                                     "/bin/sh -c 'if curl…"   49 seconds ago   Up 25 seconds                                                                                             test-probe-1
7ba743998c8a   flask-health                                     "python app.py"          50 seconds ago   Up 47 seconds (healthy)   0.0.0.0:5000->5000/tcp   

## health-probe  日志
{"status":"ok"}Health check succeeded! Container will stay alive.
```

***

### 03 harbor::docker-compose.yml 文件修改

```diff
50c50,51
<       - log
---
>       log:
>         condition: service_healthy
81c82,83
<       - log
---
>       log:
>         condition: service_healthy
106c108,109
<       - log
---
>       log:
>         condition: service_healthy
143,146c146,153
<       - log
<       - registry
<       - redis
<       - postgresql
---
>       log:
>         condition: service_healthy
>       registry:
>         condition: service_healthy
>       redis:
>         condition: service_healthy
>       postgresql:
>         condition: service_healthy
171c178,179
<       - log
---
>       log:
>         condition: service_healthy
202c210,211
<       - core
---
>       core:
>         condition: service_healthy
224c233,234
<       - log
---
>       log:
>         condition: service_healthy
252,255c262,269
<       - registry
<       - core
<       - portal
<       - log
---
>       registry:
>         condition: service_healthy
>       core:
>         condition: service_healthy
>       portal:
>         condition: service_healthy
>       log:>         condition: service_healthy
```

修改之后，使用`docker-compose up -d` 命令可以稳动启动

***

## 04 总结

1\. `depends_on`仅确保容器按指定顺序启动，但不会验证被依赖服务的实际可用性。若部署时需要确保依赖服务已完全就绪（如数据库初始化完成），则需使用 `depends_on.condition: service_healthy` 对服务进行显式声明。

