# LoongArch Kubernetes 集群部署与 MetalLB Speaker 端口问题排查

## 目录

1. 背景
2. clusterd-custom 配置及镜像代理说明
3. MetalLB Speaker 启动失败问题
   * 3.1 错误日志
   * 3.2 问题分析
   * 3.3 解决方案
4. 部署与验证
5. 总结

***

## 1. 背景

在 LoongArch 架构的 Kubernetes 集群部署中，用户遇到了一系列关于 containerd、Flannel 和 MetalLB 的问题。集群节点运行的是 LoongArch 架构的 Linux 系统，Kubernetes 版本为 1.29，部分容器镜像为 LoongArch 原生或多架构镜像。

关键背景信息：

* 集群中使用了`containerd-custom`来单独管理某些容器运行环境和镜像源，避免影响系统默认 containerd。
* `containerd-custom`使用独立配置文件`/etc/containerd-custom/config.toml`，可以单独配置镜像代理（mirrors）和其他参数。
* 节点上运行了多个长期运行的容器（如 GitLab、Nextcloud、MySQL），导致部分端口（如 7946）被占用。

***

## 2. containerd-custom 配置及镜像代理说明

### 问题描述

在部署过程中，`containerd-custom`服务无法启动，日志显示 TOML 配置解析失败：

```
failed to load TOML: /etc/containerd-custom/config.toml: (137, 29): no value can start with t 
```

### 分析

* 错误发生在`containerd-custom`的独立配置文件中，而不是系统默认 containerd。
* 配置文件错误示例：

```
ShimCgroup = "" SystemdCgroup = ture 
```

### 修复

```
SystemdCgroup = true 
```

### 注意事项

* 修改`/etc/containerd-custom/config.toml`可独立影响 containerd-custom 的行为。
* 可以单独为 containerd-custom 配置镜像代理（mirror），而不影响系统默认 containerd 配置。
* 例如：

```
[plugins."io.containerd.grpc.v1.cri".registry.mirrors."my.registry.local"] endpoint = ["https://my.registry.local"] 
```

***

## 3. MetalLB Speaker 启动失败问题

### 3.1 错误日志

部署 MetalLB 后，Speaker Pod 出现连续重启：

```
Normal Scheduled Successfully assigned metallb-system/speaker-l69ww to localhost.localdomain Normal Pulling Pulling image "metallb/speaker:0.15.2" Normal Pulled Successfully pulled image Normal Created Created container speaker Warning BackOff Back-off restarting failed container speaker 
```

查看 Pod 日志：

```
2025/09/23 02:12:14 github.com/josharian/native: unrecognized arch loong64 {"msg":"MetalLB speaker starting version 0.15.2"} {"error":"Could not set up network transport: failed to obtain an address: Failed to start TCP listener on \"10.130.0.20\" port 7946: bind: address already in use"} 
```

### 3.2 问题分析

* MetalLB Speaker 默认使用端口 7946（TCP/UDP）做 memberlist 通信。
* 系统上已有`dockerd`占用 7946 端口：

```
sudo lsof -i :7946 COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME dockerd 2193941 root 20u IPv6 13031352 0t0 TCP *:7946 (LISTEN) 
```

* Kubernetes DaemonSet 中`hostNetwork: true`时，`hostPort`必须与`containerPort`相同，否则会报错：

```
The DaemonSet "speaker" is invalid: spec.template.spec.containers[0].ports[1].hostPort: Invalid value: 7947: must match `containerPort` when `hostNetwork` is true 
```

### 3.3 解决方案

1. 修改 Speaker 容器参数，指定新的 memberlist 端口：

```
containers: - args: - --port=7472 - --log-level=info - --ml-bindport=7947 # 新端口 ports: - containerPort: 7472 name: monitoring - containerPort: 7947 name: memberlist-tcp - containerPort: 7947 name: memberlist-udp 
```

1. 原因分析：

* `--ml-bindport`指定 Speaker 内部使用的 memberlist 端口。
* `containerPort`也修改为同样的端口，满足`hostNetwork: true`的约束。
* 这样即使 7946 被系统占用，也不会影响 Speaker 的运行。

1. 部署：

```
kubectl apply -f metallb-native.yaml 
```

1. 验证：

```
kubectl get pods -n metallb-system kubectl logs speaker-l69ww -n metallb-system 
```

***

## 4. 部署与验证

* containerd-custom 启动正常，镜像拉取成功。
* MetalLB Speaker Pod 使用新端口 7947 启动正常，不再重启。
* 端口冲突问题得到解决，同时原有 dockerd 服务不受影响。

***

## 5. 总结

本次排查总结如下：

1. LoongArch 架构集群中，`containerd-custom`可以独立配置镜像代理，不影响系统默认 containerd。
2. containerd-custom 配置文件错误可能导致服务无法启动，需要注意 TOML 格式和布尔值拼写。
3. MetalLB Speaker 使用的默认 memberlist 端口可能被其他服务占用，使用`--ml-bindport`配置新端口，并同步修改`containerPort`可以解决 hostNetwork 冲突问题。
4. 整个流程无需关闭系统 dockerd，兼顾了已有服务和 MetalLB 正常运行。
