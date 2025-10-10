# Prometheus 在 LoongArch K8s 集群上部署权限问题排查与解决

## 1. 背景

在 LoongArch K8s 集群上使用 Helm 部署 `kube-prometheus-stack` 时，`Prometheus` Pod 无法正常启动。经初步排查，发现其初始化容器 `prometheus-config-reloader` 反复崩溃，导致整个 Pod 停留在 `Init:0/1` 状态。

***

## 2. 问题复现

### 2.1 部署与状态检查

在 Kubernetes 集群上直接使用 Helm 安装 `kube-prometheus-stack`：

```shellscript
# 添加并更新 Helm 仓库
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# 拉取 chart 到本地
helm pull prometheus-community/kube-prometheus-stack --untar
cd kube-prometheus-stack

# 部署
helm install yzw ./kube-prometheus-stack -n yzw --create-namespace

# 检查 Pod 状态
kubectl get pods -n yzw
```

结果显示 `prometheus-yzw-kube-prometheus-stack-prometheus-0` Pod 处于 `Pending` 或 `CrashLoopBackOff` 状态。

### 2.2 错误日志分析

通过 `kubectl describe` 命令查看 Pod 详情，发现初始化容器 `init-config-reloader` 的日志中出现权限错误：

```
Failed to run: permission denied
add config file /etc/prometheus/config/prometheus.yaml.gz to watcher
...
Exit Code: 1
```

日志显示 `init-config-reloader` 无法访问配置文件 `/etc/prometheus/config/prometheus.yaml.gz`，从而导致启动失败。

***

## 3. 问题分析

通过本地 `docker run` 方式进行模拟测试，进一步定位问题根源。

### 3.1 测试环境准备

为模拟 Pod 中的卷挂载，创建本地目录和配置文件：

```shellscript
mkdir -p test-reloader/etc/prometheus/{config,config_out,rules}
echo "global:" > test-reloader/etc/prometheus/config/prometheus.yaml
gzip -c test-reloader/etc/prometheus/config/prometheus.yaml > test-reloader/etc/prometheus/config/prometheus.yaml.gz
```

### 3.2 非 Root 用户权限测试

运行容器并挂载模拟的卷，不指定用户：

```shellscript
docker run --rm -it \
  -v $(pwd)/test-reloader/etc/prometheus/config:/etc/prometheus/config:ro \
  -v $(pwd)/test-reloader/etc/prometheus/config_out:/etc/prometheus/config_out \
  -v $(pwd)/test-reloader/etc/prometheus/rules:/etc/prometheus/rules \
  cr.loongnix.cn/prometheus/prometheus-config-reloader:0.85.0 \
  --watch-interval=0 \
  ...
```

**测试结果**：

容器日志显示 `open /etc/prometheus/config_out/prometheus.env.yaml.tmp: permission denied`。

**分析**：

`prometheus-config-reloader` 镜像的 `Dockerfile` 中设置了 `USER nobody`，导致容器以非 `root` 用户运行。该用户对挂载的 `config_out` 目录没有写权限，因此无法生成临时配置文件，容器启动失败。

### 3.3 Root 用户权限测试

在上述命令中添加 `--user 0` 参数，强制以 `root` 用户运行容器：

```shellscript
docker run --rm -it --user 0 ...
```

**测试结果**：

容器日志不再报权限错误，正常运行。这证明问题完全是由**镜像内默认用户权限不足**引起的。在 Kubernetes 中，Pod 启动时，其用户权限受**安全上下文**和**镜像内置用户**共同影响。

***

## 4. 解决方案

要解决此问题，需要修改 Helm Chart 的 `values.yaml` 文件，以调整 Prometheus Pod 的**安全上下文**，从而为 `prometheus-config-reloader` 提供足够的权限。

### 4.1 修改 `values.yaml` 配置

在 `kube-prometheus-stack/values.yaml` 文件中，找到 `prometheus` 部分，添加或修改 `securityContext` 配置：

```yaml
# values.yaml
# ...
prometheus:
  # ...
  prometheusSpec:
    # 为 Pod 设置安全上下文，使其以 root 用户运行
    securityContext:
      runAsUser: 0
      runAsGroup: 0
      fsGroup: 0
      runAsNonRoot: false
      seccompProfile:
        type: RuntimeDefault
    # ...
```

&#x20; \* **`runAsUser: 0`**：强制 Pod 内的容器以 `root` 用户身份运行。这能确保 `prometheus-config-reloader` 拥有访问和修改挂载卷的权限。

&#x20; \* **`fsGroup: 0`**：确保挂载到 Pod 中的卷由 `root` 组拥有，这对于某些需要组权限的场景非常重要。

> **注意**：此处直接使用 `root` 权限是为了快速解决问题。更安全的做法是创建一个 UID/GID，确保它对所有相关目录有读写权限，然后让容器以该用户运行。但考虑到当前镜像的用户设置，直接使用 `root` 是最有效的解决方案。

### 4.2 部署流程

完成 `values.yaml` 修改后，重新部署或升级 Helm Chart：

1. **清理旧的 Pod**：
   ```shellscript
   kubectl delete -n yzw pod prometheus-yzw-kube-prometheus-stack-prometheus-0
   ```

&#x20;   \`\`\`

1. **重新安装或升级**：
   ```shellscript
   helm upgrade --install yzw ./kube-prometheus-stack -n yzw
   ```

&#x20;   \`\`\`

1. **验证结果**：
   ```shellscript
   kubectl get pods -n yzw
   ```

&#x20;   \`\`\`

&#x20;   验证 `prometheus` Pod 状态是否从 `Pending` 或 `CrashLoopBackOff` 变为 `Running`。如果 Pod 启动成功，可以进一步通过 `kubectl describe` 命令确认 `init-config-reloader` 不再有权限错误。

***

## 5. 总结

本次部署失败的根本原因在于 `Prometheus` 的 `init-config-reloader` 容器**权限不足**。该容器镜像默认以非 `root` 用户运行，导致其对配置文件卷没有写入权限。通过在 Helm Chart 的 `values.yaml` 中设置 Pod 的 `securityContext`，强制其以 `root` 用户运行，即可解决此权限问题，使 Prometheus 服务能够正常启动。
