# kubernetes 应用实例（以gohttpfilerserver为例）

# 背景

使用k8s集群进行文件服务器管理、cloud软件包仓库维护、CI/CD服务运行的优势：

## 1. 客户问题验证

* **快速复现环境**：可以用 YAML/Helm 一键拉起客户所用组件，复现环境一致，避免“环境不同步”问题。
* **多版本共存**：同一个集群里能同时部署不同版本的应用，方便对比和定位问题。
* **隔离性强**：每个验证环境都在独立的命名空间/Pod 中运行，不会互相影响。

***

## 2. 学习使用

* **标准化平台**：Kubernetes 已成为主流容器编排平台，学习它就等于掌握行业标准。
* **丰富的生态**：围绕 K8s 的开源组件多（监控、日志、存储、网络），学习过程能接触到全栈实践。
* **贴近生产**：学习环境和企业生产环境一致，避免学到“玩具工具”。

## 3. 文件服务器管理

* **高可用性**：文件服务 Pod 可以通过 Deployment/StatefulSet 保证**多个副本同时运行**，在单点故障时流量会自动切换，提升整体可用性。
* **弹性扩展**：存储和服务节点可以随需求增加，避免性能瓶颈。
* **统一存储接入**：借助 CSI 插件，可以挂载多种后端存储（NFS、Ceph、对象存储），灵活性高。
* **安全可控**：基于 ServiceAccount、NetworkPolicy 管理访问权限，比传统裸机共享更可控。

***

## 4. Cloud 软件包仓库维护

* **镜像/包统一管理**：可以通过 K8s 部署 Harbor、Nexus 等仓库，实现容器镜像和软件包的集中管理。
* **负载均衡与扩展**：仓库服务支持**多副本部署**，并通过 Service 自动进行流量均衡，保证高并发下载时的稳定性。
* **多架构支持**：配合 K8s 节点标签，可以针对不同 CPU 架构/ABI 构建和分发软件包。
* **自动化运维**：通过 Operator 或 CronJob 自动执行仓库同步、清理、备份。

## 5. CI/CD 服务运行

* **弹性计算资源**：CI/CD 构建任务可以以 Job/Pod 形式动态拉起，任务完成后自动释放，节约资源。
* **环境一致性**：构建环境容器化，避免“开发能跑，生产出错”的问题。
* **流水线扩展性**：Jenkins、GitLab Runner、Tekton 等都能在 K8s 上原生运行，方便扩展。
* **安全隔离**：每个流水线 Pod 独立运行，降低相互干扰和安全风险。

***

## 6. 共性优势（适用于所有场景）

1. **标准化管理**：统一 API 接口和 YAML 描述，降低运维复杂度。
2. **资源高效利用**：按需调度，避免服务器资源浪费。
3. **跨平台能力**：不论是物理机、虚拟机、公有云、私有云，都能统一运行。
4. **自动化和自愈**：Pod 异常自动拉起，节点故障可自动迁移。
5. **生态完善**：可与监控、日志、服务网格等无缝集成，支撑从实验到生产的全链路。

本文档详细介绍在 **LoongArch 架构**下，通过 Kubernetes 部署文件服务应用的全流程，涵盖节点规划、环境配置、组件安装、服务部署及外部访问方案。文档中适当补充了概念说明和原理解析，便于理解集群部署的背景与思路。

配置文件下载地址：http://cloud.loongnix.xa/os-packages/k8s/deploy-yaml-k8s-demo.tar.gz

***

## 1. K8s 节点分配

* **Master 节点**：1 个

&#x20; \* 负责集群控制平面，包括调度、API Server、etcd、falnnel 等核心组件。

* **Node 节点**：1-2 个

&#x20; \* 承载应用 Pod 的运行。

&#x20; \* 可以通过标签或节点选择器指定 Pod 部署位置，提高调度灵活性。

> **知识点**：Kubernetes 集群的核心架构分为控制平面（Master）和工作节点（Node）。Master 负责管理集群状态，Node 执行具体的应用容器。

***

## 2. K8s 启动前环境准备（所有节点执行）

```
# 设置主机名
hostnamectl set-hostname k8s-master   # Master 节点
hostnamectl set-hostname k8s-node     # Worker 节点

# 关闭安全与网络防护
setenforce 0
systemctl stop firewalld.service
systemctl disable firewalld.service

# 关闭 swap 分区（Kubernetes 要求关闭 swap）
swapoff -a
sed -ri '/\sswap\s/s/^#?/#/' /etc/fstab

# 清理 iptables 规则，保证网络插件正常工作
iptables -F; iptables -X; iptables -Z
iptables -t nat -F; iptables -t nat -X; iptables -t nat -Z

# 配置 hosts 域名映射
cat >> /etc/hosts << EOF
<Master节点IP> k8s-master
<Worker节点IP> k8s-node
EOF

# 加载内核模块
cat << EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# 配置网络转发参数
cat << EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
sysctl --system
```

> **知识点**：
> containerd 是 Kubernetes 官方推荐的容器运行时，替代 Docker。
>
> `SystemdCgroup = true`可以让 containerd 和系统的 cgroup 统一管理资源。
>
> `pause`镜像用于 Pod 网络初始化，是 Pod 内各容器共享网络命名空间的基础。

***

## 3. 安装 containerd（推荐 1.7.x 版本）

```
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml

# 修改关键参数
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
  SystemdCgroup = true        # 使用 systemd 管理 cgroup
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "lcr.loongnix.cn/kubernetes/pause:3.9"  # pause 镜像
```

***

## 4. 安装 Kubernetes 组件（v1.29.0 版本）

```
mkdir -p /tmp/rpms && cd /tmp/rpms
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/{cri-tools-1.29.0-0.loongarch64.rpm,kubeadm-1.29.0-0.loongarch64.rpm,kubectl-1.29.0-0.loongarch64.rpm,kubelet-1.29.0-0.loongarch64.rpm,kubernetes-cni-1.3.0-0.loongarch64.rpm}

yum install -y ./*.rpm
```

***

## 5. 配置 crictl

```
cat << EOF | tee /etc/crictl.yaml
runtime-endpoint: unix:///run/containerd/containerd.sock
EOF
```

> **知识点**：

> `crictl` 是容器运行时调试工具，用于检查 containerd 或 CRI-O 状态。

***

## 6. Master 节点初始化

```
kubeadm init \
  --image-repository lcr.loongnix.cn/kubernetes \
  --kubernetes-version v1.29.0 \
  --cri-socket=/run/containerd/containerd.sock \
  --pod-network-cidr=10.244.0.0/16 -v=5

mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config
```

> **知识点**：

* `pod-network-cidr`用于指定 Pod 网段，与 Flannel 或其他 CNI 插件对应。
* `kubeadm init`会生成 join 命令，用于 Node 节点加入集群。



  &#x20;   清空环境（主节点和worker节点）
  ````
     - 清空之前部署缓存
  	```
  	sudo kubeadm reset
  	rm -rf ~/.kube
  	sudo rm -rf /etc/cni/net.d
          ip link delete cni0
          ip link delete flannel.1
          ifconfig cni0 down
          ip link delete cni0
          ifconfig flannel.1 down
          ip link delete flannel.1
          rm -rf /var/lib/cni/
  rm -f /etc/cni/net.d/*
  	```
  ````

***

## 7. Node 节点加入集群

```
kubeadm join <Master_IP>:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash>
```

> **提示**：确保 Node 节点的时间同步，否则可能因 TLS 认证失败无法加入集群。
> 注意： 如果待加入的worker 已经有在工作的containerd了且版本较低不符合要求，我们可以新建一个containerd服务，起名为containerd-custom。重写它的service配置，在join时加入参数--cri-socket unix:///run/containerd-custom/containerd.sock

***

## 8. 安装 Flannel 网络插件

```
wget https://github.com/Loongson-Cloud-Community/flannel/releases/download/v0.24.3/kube-flannel.yml
# 修改 pod-network-cidr 与 kubeadm init 保持一致
kubectl apply -f kube-flannel.yml
```

> **知识点**：

* Flannel 提供 Overlay 网络，使 Pod 可以跨节点通信。
* 常用网络插件还有 Calico、Cilium，可根据需求选择。

***

## 9. 确认节点状态



```
kubectl get nodes
```

> 所有节点状态应为 `Ready`，表示集群节点已成功注册并可调度 Pod。
> cni插件最好使用flannel 不要用calico 我解决不了
> containerd 版本不要用2.X的
> 如果node还是notready  尝试restart containerd和kubelet试试

***

## 10. 配置应用文件共享（NFS 方案）

### Master 节点（NFS 服务器）

```
yum install -y nfs-utils
echo "/test *(rw,sync,no_root_squash)" >> /etc/exports
systemctl enable --now nfs-server
exportfs -a
```

### Node 节点（NFS 客户端）

```
mkdir -p /test
mount -t nfs <Master_IP>:/test /test
```

> **知识点**：

* NFS 共享用于存储共享文件，例如应用包或日志。
* `no_root_squash`允许节点以 root 权限访问共享目录。

***

## 11. 部署 Go HTTP 文件服务器（NodePort）

### 部署清单 httpfile.yaml

```
apiVersion: v1
kind: Namespace
metadata:
  name: os-packages

apiVersion: apps/v1
kind: Deployment
metadata:
  name: gohttpserver
  namespace: os-packages
spec:
  replicas: 3
  selector:
    matchLabels:
      app: gohttpserver
  template:
    metadata:
      labels:
        app: gohttpserver
    spec:
      nodeSelector:
        os-packages: "true"
      containers:
      - name: gohttpserver
        image: lcr.loongnix.cn/codeskyblue/gohttpserver:1.3.0
        ports:
        - containerPort: 8000
        volumeMounts:
        - name: packages-volume
          mountPath: /app/public
      volumes:
      - name: packages-volume
        hostPath:
          path: /os-packages
          type: Directory

apiVersion: v1
kind: Service
metadata:
  name: gohttpserver-svc
  namespace: os-packages
spec:
  selector:
    app: gohttpserver
  ports:
    - port: 8000
      targetPort: 8000
  type: NodePort
```

### 部署与访问

```
kubectl apply -f httpfile.yaml
kubectl get svc gohttpserver-svc -n os-packages
http://<Node_IP>:<NodePort>
```

> **知识点**：

* NodePort 将服务暴露到每个节点的随机高端口（30000-32767）。
* NodePort 简单，适合测试环境，不适合生产级负载均衡。

***

## 12. 集群外访问方案（MetalLB + Ingress）

##### 顺序： metallb-native  -> metallb-config -> ingress

### 部署 MetalLB

这里忽略了metallb-native文件

> 注意： 可能会出现Error from server (InternalError): error when creating "kuber-fiels/confi\_metalLB.yaml": Internal error occurred: failed calling webhook "l2advertisementvalidationwebhook.metallb.io": failed to call webhook: Post "[https://webhook-service.metallb-system.svc:443/validate-metallb-io-v1beta1-l2advertisement?timeout=10s](https://webhook-service.metallb-system.svc/validate-metallb-io-v1beta1-l2advertisement?timeout=10s)": dial tcp 10.100.2.163:443: connect: connection refused 这样的错误，需要在nativc配置里将failurePolicy: 配置从fail修改成Ignore

```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: yzewei-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.130.0.200-10.130.0.215
#这里的ip 选取空闲区域

apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2
  namespace: metallb-system
```

> 需要注意ingress的yaml文件最好和版本对应，否则可能出现由于ingress需要ip的选举权限，但是由于yaml和镜像不匹配导致策略过时，最终运行失败
> 地址https://github.com/kubernetes/ingress-nginx/blob/controller-v1.1.1/deploy/static/provider/cloud/deploy.yaml



### 部署 Ingress

```
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: os-packages-ingress
  namespace: os-packages
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: cloudos.loongnix.cn
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gohttpserver-svc
            port:
              number: 8000
```

### 重新部署gohttpfileserver服务



> 1\. 可能在上面已经分配了ip池后，ingress也部署成功，但是应用需要使用ip来进行webhook 调用失败的情况 如 \[root@k8s-master deploy]# kubectl apply --validate=false -f file-server-ingress.yaml namespace/os-packages unchanged deployment.apps/gohttpserver unchanged service/gohttpserver-svc unchanged Error from server (InternalError): error when creating "file-server-ingress.yaml": Internal error occurred: failed calling webhook "validate.nginx.ingress.kubernetes.io": failed to call webhook: Post "https://ingress-nginx-controller-admission.ingress-nginx.svc:443/networking/v1/ingresses?timeout=10s": EOF
> 此时需要删除或禁用 Validating Webhook
> 执行kubectl delete validatingwebhookconfiguration ingress-nginx-admission
> 接着再次执行
>
> 2\. 还需要将os-package 的label打好标签

```
kubectl label node k8s-node  os-packages=true
kubectl label node k8s-node1 os-packages=true
kubectl label node kubernetes-master-1 os-packages=true
```

> 下面的CRD 不仅修改了pod的类型，从LoadBanlancer改为ClusterIP，方便ingress 转发流量，同时新增了Ingress 资源 名字为os-packages-ingress 分配了ip

```
[root@k8s-master deploy]# cat file-server-ingress.yaml 
apiVersion: v1
kind: Namespace
metadata:
  name: os-packages
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gohttpserver
  namespace: os-packages
spec:
  replicas: 3
  selector:
    matchLabels:
      app: gohttpserver
  template:
    metadata:
      labels:
        app: gohttpserver
    spec:
      containers:
      - name: gohttpserver
        image: lcr.loongnix.cn/codeskyblue/gohttpserver:1.3.0
        ports:
        - containerPort: 8000
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 512Mi
        volumeMounts:
        - name: packages-volume
          mountPath: /app/public   # gohttpserver 的默认公开目录
      volumes:
      - name: packages-volume
        hostPath:
          path: /os-packages       # 节点上的目录
          type: Directory

---
apiVersion: v1
kind: Service
metadata:
  name: gohttpserver-svc
  namespace: os-packages
spec:
  selector:
    app: gohttpserver
  ports:
    - port: 8000       # Service 内部端口
      targetPort: 8000 # Pod 的端口
      protocol: TCP
  type: ClusterIP      # 这里必须用 ClusterIP，Ingress 通过它转发流量 之前是Nodeport

---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: os-packages-ingress
  namespace: os-packages
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /   # 可选，看路径转发需求
spec:
  ingressClassName: nginx   # 必须指定，匹配 ingress-nginx-controller
  rules:
  - host: cloudos.loongnix.cn
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: gohttpserver-svc
            port:
              number: 8000

```

### 访问方式

```
kubectl -n ingress-nginx get svc
http://10.130.0.200/
# 或配置 hosts 域名访问
10.130.0.200  cloudos.loongnix.cn
```

> **知识点**：ingress\_metallb组合的方式可以减少ip的占有率，所有服务都使用一个EXTERNAL\_IP ，需要通过dns缓存配置（网关路由或本地配置域名） 解决访问问题。
> 后续的prometheus、grafana等均与该gohttpfileserver服务使用同一配置IP

***

## 13. 监控方案

使用常用的监控套件 prometheus+grafana+node-exporter

这里使用到了helm，helm是一种集成插件，使用它可以对镜像进行自动的拉取，在k8s上的构建。

### 下载安装helm：

```
wget https://cloud.loongnix.cn/releases/loongarch64/helm/helm/3.18.2/helm-v3.18.2-linux-loong64.tar.gz
tar xf helm-v3.18.2-linux-loong64.tar.gz
mv linux-loong64/helm /usr/local/bin 
```

### 修改每个节点的containerd配置

```
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."*"]
              endpoint = ["https://cr.loongnix.cn"]
```

这里是为了在helm为不同的node 进行imagepull时，不会因为架构差异或者abi差异导致拉取的镜像不符合当前node导致报错。

&#x20;   接着执行下面的命令使配置生效并测试。

```
containerd config dump
systemctl restart containerd
crictl --debug=true pull debian:buster
```

### 修改helm的配置文件

&#x20;   在这里主要对比cr 仓库、lcr仓库下 需要的镜像的tag差别。

1. 接受不同架构node使用不同tag的插件 且所有mirror仓库均有latest，那么设置配置里该插件镜像tag为latest
2. 不接受1的前置条件，那么需要自行构建缺失的镜像
3. 如果存在需要指定在某个abi部署的服务，需要在values.yaml中添加nodeSelector
4. helm 中的子chart下的value.yaml也需要配置
5. 如果对配置文件中的镜像tag置空，helm会从Chart.yaml获取
6. tag尽量不要使用latest因为可能 会有限制，如下：

> \<Error: INSTALLATION FAILED: template: kube-prometheus-stack/charts/prometheus-node-exporter/templates/daemonset.yaml:60:19: executing "kube-prometheus-stack/charts/prometheus-node-exporter/templates/daemonset.yaml" at \<semverCompare ">=1.4.0-0" (coalesce .Values.version .Values.image.tag .Chart.AppVersion)>: error calling semverCompare: Invalid Semantic Version>

1. 设置nodeSelector时要在pod级别下才有效

#### 启动服务

```
helm install my-prometheus ./kube-prometheus-stack -n monitoring --create-namespaceNAME: my-prometheus
LAST DEPLOYED: Thu Sep 18 17:35:32 2025
NAMESPACE: monitoring
STATUS: deployed
REVISION: 1
NOTES:
kube-prometheus-stack has been installed. Check its status by running:
  kubectl --namespace monitoring get pods -l "release=my-prometheus"

Get Grafana 'admin' user password by running:

  kubectl --namespace monitoring get secrets my-prometheus-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo

Access Grafana local instance:

  export POD_NAME=$(kubectl --namespace monitoring get pod -l "app.kubernetes.io/name=grafana,app.kubernetes.io/instance=my-prometheus" -oname)
  kubectl --namespace monitoring port-forward $POD_NAME 3000
Visit https://github.com/prometheus-operator/kube-prometheus for instructions on how to create & configure Alertmanager and Prometheus instances using the Operator.
```

> 卸载命令：helm uninstall my-prometheus -n monitoring



## 14. 方案总结

* NodePort：简单易用，适合测试。
* MetalLB + Ingress：生产环境首选，支持固定 IP、域名路由和负载均衡。
* Flannel/Calico 网络插件确保 Pod 跨节点通信。
* NFS 或 CephFS 等共享存储可提供多节点文件访问。

> **最佳实践提示**：

* 生产环境建议开启防火墙并配置安全策略。
* 监控和日志建议使用 Prometheus + Grafana + Loki。
* 定期升级 Kubernetes 和容器运行时，保证安全性。



### 附录

#### 异构混部问题

为了解决k8s集群多个终端worker可能存在不同架构（x86 arm loongarch）或不同abi（abi1  abi2）节点的问题，考虑以下难点：

1. k8s核心二进制版本需要相同，如kubelet kubeadm 等
2. containerd 版本需要同步
3. crictl的mirror仓库中的镜像版本需要对齐
4. 调度器并不会区分abi，如果需要指定在abi2/1上执行的任务需要手动指定worker的label，并在crd的nodeSelector中调度。
5. helm进行安装服务时需要注意values.yaml的修改

#### 节点出现containerd卡死

> failed to unmount target ... rootfs: device or resource busy
> 该日志说明containerd 想清理那个 Pod 的 rootfs，但挂载点还被占用着，结果整个 containerd 被拖死了，启动不干净。

##### 解决步骤

1\. 确认占用情况

找出是哪个进程卡住了这个挂载点：

```
fuser -vm /home/containerd/state/io.containerd.runtime.v2.task/k8s.io/4c1757da6a73d4175d825ab0328d8fe5e11c9bcc715e86d5acae8d43d615978b/rootfs # 或 lsof +D /home/containerd/state/io.containerd.runtime.v2.task/k8s.io/4c1757da6a73d4175d825ab0328d8fe5e11c9bcc715e86d5acae8d43d615978b/rootfs 
```

如果有进程还在用，强制 kill：

```
kill -9 <PID> 
```

2\. 强制卸载挂载点

```
umount -l /home/containerd/state/io.containerd.runtime.v2.task/k8s.io/4c1757da6a73d4175d825ab0328d8fe5e11c9bcc715e86d5acae8d43d615978b/rootfs 
```

这里必须用`-l`（lazy umount），否则 device busy 会卸不掉。

***

3\. 删除残留目录

```
rm -rf /home/containerd/state/io.containerd.runtime.v2.task/k8s.io/4c1757da6a73d4175d825ab0328d8fe5e11c9bcc715e86d5acae8d43d615978b 
```

***

4\. 重启 containerd

```
systemctl restart containerd
```

#### Grafana 启动失败

报错：Readiness probe failed: Get "http://10.156.4.6:3000/api/health": dial tcp 10.156.4.6:3000: connect: connection refused

可能是因为`initialDelaySeconds`太短，容器启动慢，probe 在服务还没完全起来时就打探

修改

```
readinessProbe:
  httpGet:
    path: /api/health
    port: 3000
  initialDelaySeconds: 60  # 可改成 90 或 120，根据实际启动时间  periodSeconds: 10
```

helm 下可以指定chart upgrade ，如：`helm upgrade --install yzw ./kube-prometheus-stack -n yzw -f kube-prometheus-stack/charts/grafana/values.yaml`


等待即可



等待调试prometheus  启动问题 

尝试prometheus/prometheus-config-reloader最新版本

abi2
