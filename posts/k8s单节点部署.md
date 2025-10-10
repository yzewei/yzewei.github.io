# k8s单节点部署

## 一、相关资源链接



1. [containerd-1.7.13下载地址](https://github.com/Loongson-Cloud-Community/containerd/releases/download/v1.7.13/containerd-1.7.13-static-abi2.0-bin.tar.gz)
2. [k8s-1.29相关资源地址](http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/)
3. [runc-1.1.12下载地址](https://github.com/Loongson-Cloud-Community/runc/releases/download/v1.1.12/runc-seccomp-1.1.12-abi2.0-bin.tar.gz)
4. [Netfilter-packet-flow](https://upload.wikimedia.org/wikipedia/commons/3/37/Netfilter-packet-flow.svg)

##

## 二、部署环境准备

1. 关闭 swap 分区：`swapoff -a`，避免因内存管理不准确而导致容器调度和性能问题。
2. 关闭 selinux： `setenforce 0`，为了避免其限制影响容器的正常运行。SELinux 的策略可能会阻止容器访问必要的资源或执行必需的操作，导致 Kubernetes 的组件无法正常工作。为了简化配置和减少出错的可能性，通常建议禁用 SELinux 或将其设置为 Permissive 模式，这样可以避免与 Kubernetes 的兼容性问题。
3. 检查加载必要的内核模块

```shellscript
modprobe overlay
modprobe br_netfilter
```

* overlay：overlay 是 OverlayFS 的内核驱动，用于支持容器分层文件系统。Kubernetes 依赖容器运行时（如 Containerd、Docker）管理容器，而 OverlayFS 是容器镜像分层存储和联合挂载的基础。
* br\_netfilter：桥接流量过滤。br\_netfilter 允许 Linux 内核的 iptables/nftables 对桥接网络流量进行过滤和 NAT 转换。



1. 设置 k8s 内核配置选项，执行`sysctl -p /etc/sysctl.d/99-kubernetes-cri.conf` 使其生效。这部分内核选项主要是为了支持Calico、Weave、Flannel 等网络插件的使用。

```shellscript
cat <<EOF | sudo tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
```



1. 关闭防火墙

```shellscript
  systemctl stop firewalld
```



1. 修改hosts文件

```shellscript
机器ip lab1
```



1. 修改hostname

```
hostname lab1
```

 

## 三、安装runc

```shellscript
wget https://github.com/Loongson-Cloud-Community/runc/releases/download/v1.1.12/runc-seccomp-1.1.12-abi2.0-bin.tar.gz
tar -xf runc-seccomp-1.1.12-abi2.0-bin.tar.gz
mv runc-seccomp-1.1.12-abi2.0-bin/runc-static /usr/local/bin/runc
```

## 四、安装containerd



1. 下载安装containerd二进制

```
wget https://github.com/Loongson-Cloud-Community/containerd/releases/download/v1.7.13/containerd-1.7.13-static-abi2.0-bin.tar.gz
tar -xf containerd-1.7.13-static-abi2.0-bin.tar.gz
mv containerd-1.7.13-static-abi2.0-bin/* /usr/local/bin/
```



1. 生成containerd默认配置文件

```shellscript
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
```



1. 修改 /etc/containerd/config.toml， 将systemd 作为容器的cgroup driver:

```toml
 [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
   ...
   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
     SystemdCgroup = true
```



1. 修改 /etc/containerd/config.toml， 指定的pause容器部分:

```toml
[plugins."io.containerd.grpc.v1.cri"]
  sandbox_image = "lcr.loongnix.cn/kubernetes/pause:3.9"
```



1. 为了通过 systemd 启动 containerd ，请还需要从 https://raw.githubusercontent.com/containerd/containerd/main/containerd.service 下载 containerd.service 单元文件，并将其放置在 /etc/systemd/system/containerd.service 中

```shellscript
wget https://raw.githubusercontent.com/containerd/containerd/main/containerd.service
mv containerd.service /etc/systemd/system/containerd.service
```



1. 启动 containerd

```shellscript
systemctl daemon-reload
systemctl start containerd
```

## 五、k8s安装

```shellscript
mkdir -p /tmp/rpms
cd /tmp/rpms
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/cri-tools-1.29.0-0.loongarch64.rpm
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/kubeadm-1.29.0-0.loongarch64.rpm
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/kubectl-1.29.0-0.loongarch64.rpm
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/kubelet-1.29.0-0.loongarch64.rpm
wget http://cloud.loongnix.cn/releases/loongarch64/kubernetes/kubernetes/v1.29.0/kubernetes-cni-1.3.0-0.loongarch64.rpm
yum install -y ./*.rpm
```

## 六、配置 crictl

```shellscript
 ## 配置runtime-endpoint
 crictl config runtime-endpoint unix:///run/containerd/containerd.sock
 ## 配置image-endpoint
 crictl config image-endpoint unix:///run/containerd/containerd.sock
```

## 七、创建 k8s 集群

```shellscript
kubeadm init \
--image-repository lcr.loongnix.cn/kubernetes \
--kubernetes-version v1.29.0 \
--cri-socket=/run/containerd/containerd.sock \
--pod-network-cidr=10.244.0.0/16 -v=5
```

* `--image-repository`：指定 kubernetes 的镜像仓库
* `--kubernetes-version`：指定 kubernetes 的镜像版本
* `--cri-socket`：指定 cri 组件的 `.sock` 文件位置
* `--pod-network-cidr=10.244.0.0/16`：指定 pod 的 ip 范围
* `-v=5`：指定 kubeadm 的日志级别，一般不指定，这里指定主要是为了方便排查错误



出现类似如下日志，代表启动成功

```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

You should now deploy a pod network to the cluster.
Run "kubectl apply -f [podnetwork].yaml" with one of the options listed at:
  https://kubernetes.io/docs/concepts/cluster-administration/addons/

Then you can join any number of worker nodes by running the following on each as root:

kubeadm join 10.130.0.193:6443 --token dpl4ij.njlpwjg3bzg8up0k \
	--discovery-token-ca-cert-hash sha256:7990c6a4850f6c4e1f1a45855e76fb0852e8113f63ff0b8ddfa252f3da2d5d10 
```

* `https://kubernetes.io/docs/concepts/cluster-administration/addons/` ：这个站点上包含了k8s 所有的网络组件的介绍和配置方法
* `kubeadm join 10.130.0.193:6443 --token dpl4ij.njlpwjg3bzg8up0k --discovery-token-ca-cert-hash sha256:7990c6a4850f6c4e1f1a45855e76fb0852e8113f63ff0b8ddfa252f3da2d5d10` ：k8s的 slave 节点可以通过这个命令注册到当前节点

