# k8s集群 内部业务部署策略

# Kubernetes 集群内部业务部署策略说明

## 一、集群概况

**abi 1.0 2.0混合部署**

* **Kubernetes 版本**：v1.29.0
* **集群节点**：共 5 个节点

&#x20; \* 控制平面节点：`k8s-master`

&#x20; \* 普通计算节点：`k8s-node`、`k8s-node1`、`k8s-abi1-01`、`kubernetes-master-1`

* **节点架构**：LoongArch (`loong64`)，操作系统为 Linux
* **集群网络**：`flannel` 提供 Pod 网络通信；`metallb` 提供 LoadBalancer IP 分发，支持多节点多 IP 外部访问
* **ip共用**：四层负载均衡实现单ip 多服务
* **Ingress 控制器**：`ingress-nginx` 部署在独立命名空间，提供外部 HTTP/HTTPS 接入

**建设初衷**：统一管理内部构建节点，实现多版本构建和测试环境集中化，降低物理机运维和测试成本。

***

## 二、命名空间与业务分类

集群内部业务按照命名空间和功能进行隔离部署：

| 命名空间                    | 业务服务/组件                                                                       | 类型/用途                              |
| ----------------------- | ----------------------------------------------------------------------------- | ---------------------------------- |
| `cloud-app`             | gohttpserver                                                                  | 核心二进制仓库服务（deb/rpm），集中管理云计算包构建和分发   |
| `nexus-helmrepo`        | nexus                                                                         | 存储 Helm 包的仓库服务                     |
| `ingress-nginx`         | ingress-nginx-controller                                                      | Ingress 控制器，支持外部域名访问与流量管理          |
| `kube-system`           | coredns、kube-apiserver、kube-controller-manager、kube-scheduler、kube-proxy、etcd | Kubernetes 系统组件，保证集群基础功能正常         |
| `kube-flannel`          | flannel-daemonset                                                             | 网络插件，提供 Pod 间通信                    |
| `metallb-system`        | controller、speaker                                                            | LoadBalancer IP 管理                 |
| `yzw`                   | Prometheus/Kube-Prometheus/Grafana                                            | 监控系统，采集集群和业务指标，可用于客户镜像 CPU 占用观察与分析 |
| `nacos203` / `nacos223` | nacos 服务                                                                      | 配置中心测试服务                           |
| `portainer`             | portainer                                                                     | 容器管理测试服务                           |
| ...                     | ...                                                                           | 更多测试/服务                            |

> **存储策略**：`cloud`、`nexus`、`helm` 以及后续业务数据统一挂载在内部 NFS（IP: `141`），保证数据持久化和跨节点访问。

***

## 三、服务暴露与访问策略

1. **内部服务**：

&#x20;  \* 核心业务和监控组件主要采用 `ClusterIP`，集群内部访问和服务发现。

&#x20;  \* Pod 标签和 Service 选择器实现负载均衡。

1. **外部访问**：

&#x20;  \* 通过 `Ingress + Metallb` 暴露外部服务，支持 HTTP/HTTPS。

&#x20;  \* 可在 DNS 节点或本地 DNS 上配置 IP 与域名，实现统一访问。

&#x20;  \* 所有业务访问外网无需额外配置端口映射，方便内部统一管理。

1. **监控访问与调试**：

&#x20;  \* Grafana、Prometheus 暴露为 ClusterIP，通常通过 Ingress 或端口转发访问。

&#x20;  \* 对客户运行镜像出现 CPU 占用高的情况，可在集群上部署监控组件观察指标并记录数据。

&#x20;  \* 计划将监控数据持久化到 NFS（IP: `141`），保证历史指标长期可用。

***

## 四、部署策略与高可用

1. **Pod 副本与调度**：

&#x20;  \* 核心业务应用如 `gohttpserver` 部署多副本（3 个 Pod），保证高可用性。

&#x20;  \* 通过 Node Affinity 和 Label 控制 Pod 调度到合适节点，提高资源利用率。

1. **系统组件冗余**：

&#x20;  \* CoreDNS、kube-proxy、flannel DaemonSet 在每个节点部署，保证基础功能冗余。

&#x20;  \* Metallb speaker DaemonSet 在每个节点运行，保证 LoadBalancer IP 分发可用。

1. **存储策略**：

&#x20;  \* 业务数据和 Helm/Nexus 包存储统一挂载 NFS（IP: `141`），保证跨节点共享。

&#x20;  \* 未来监控数据也计划持久化到同一 NFS，避免数据丢失。

1. **升级与测试策略**：

&#x20;  \* 非正式业务服务（`nacos`、`portainer`）用于验证部署和配置策略，降低对正式业务的影响。

&#x20;  \* Helm Chart、二进制包等先在测试命名空间验证，再推广到生产命名空间。

***

## 五、节点标签与调度策略

为了支持不同特性的工作负载，集群对 Worker 节点进行了标签划分，便于 Pod 根据资源或架构要求调度到合适节点：

1. **节点类型及标签**：

&#x20;  \* ABI1 节点（`abi=1`）用于部分测试或特定架构需求的工作负载

&#x20;    \* 节点示例：`k8s-abi1-01`、`kubernetes-master-1`

&#x20;    \* 标签规则：`node.kubernetes.io/instance-abi=1`

&#x20;  \* ABI2 节点（`abi=2`）用于主力业务和正式生产负载

&#x20;    \* 节点示例：`k8s-master`、`k8s-node`、`k8s-node1`

&#x20;    \* 标签规则：`node.kubernetes.io/instance-abi=2`

1. **Pod 调度策略**：

&#x20;  \* 使用 **NodeSelector** 或 **NodeAffinity** 将 Pod 调度到指定 ABI 节点，保证应用与节点架构匹配。

&#x20;  \* 核心业务（cloud 仓库、Helm 仓库等）优先调度到 ABI2 节点，保证稳定性和性能。

&#x20;  \* 测试或轻量任务可以调度到 ABI1 节点，降低对主业务节点的影响。

1. **管理规范**：

&#x20;  \* 节点标签统一使用 `node.kubernetes.io/...` 前缀，便于识别和运维管理。

&#x20;  \* 新增节点时，需按照 ABI 类型和业务特性设置相应标签，保持调度策略一致性。

> 通过节点标签管理策略，实现了业务与节点特性匹配、负载隔离和统一运维的目标，同时为未来不同架构（ABI）应用的兼容和扩展提供了基础。

***

## 六、总结与策略要点

1. **统一管理构建节点**：集中管理 cloud 仓库、Helm 仓库，统一 NFS 存储，提高开发与测试效率。
2. **命名空间隔离**：不同业务/服务分区，便于管理、监控和权限控制。
3. **服务暴露分层**：ClusterIP 服务内网访问，Ingress + LoadBalancer 暴露外网访问。
4. **高可用与冗余**：核心业务多副本，系统组件全节点部署。
5. **监控策略**：Prometheus/Grafana 不仅监控集群本身，也可用于客户镜像运行分析，未来数据持久化到 NFS。
6. **节点调度与标签管理**：通过 ABI 标签区分不同特性节点，实现负载隔离和资源优化。
7. **测试先行策略**：测试业务验证部署方案，降低生产风险。

***

