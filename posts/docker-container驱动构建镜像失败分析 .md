# docker-container驱动构建镜像失败分析

# docker-container驱动构建镜像失败分析

## 一、问题背景

在构建 BuildKit 镜像时，使用了 0.12.3 版本的 BuildKit 镜像作为 docker-container 驱动。构建过程中，在执行 Dockerfile 中的解压操作（`tar xf buildx-linux-loong64.tar.gz`）时，出现了如下错误：

```shellscript
[root@euler2403-52 buildkit]# docker buildx build .
[+] Building 4.0s (7/7) FINISHED                                                            docker-container:alpine
 => [internal] load build definition from Dockerfile                                                           0.1s
 => => transferring dockerfile: 280B                                                                           0.0s
 => [internal] load metadata for lcr.loongnix.cn/library/debian:sid                                            0.6s
 => [internal] load .dockerignore                                                                              0.1s
 => => transferring context: 2B                                                                                0.0s
 => [1/4] FROM lcr.loongnix.cn/library/debian:sid@sha256:5504d4082ed005c1fa621740095402f0af6da4b2037a21c067cc  0.1s
 => => resolve lcr.loongnix.cn/library/debian:sid@sha256:5504d4082ed005c1fa621740095402f0af6da4b2037a21c067cc  0.1s
 => CACHED [2/4] RUN apt-get update && apt-get install -y wget tar                                             0.0s
 => CACHED [3/4] RUN wget http://cloud.loongnix.cn/releases/loongarch64/docker/buildx/0.12.0-rc1/buildx-linux  0.0s
 => ERROR [4/4] RUN tar  xf buildx-linux-loong64.tar.gz                                                        2.7s
------                                                                                                              
 > [4/4] RUN tar  xf buildx-linux-loong64.tar.gz:                                                                   
1.533 tar: bin/build: Cannot change mode to rwxr-xr-x: Operation not permitted                                      
1.533 tar: bin: Cannot change mode to rwxr-xr-x: Operation not permitted
1.533 tar: Exiting with failure status due to previous errors
------
WARNING: No output specified with docker-container driver. Build result will only remain in the build cache. To push result image into registry use --push or to load image into docker use --load
Dockerfile:6
--------------------
   4 |     
   5 |     RUN wget http://cloud.loongnix.cn/releases/loongarch64/docker/buildx/0.12.0-rc1/buildx-linux-loong64.tar.gz 
   6 | >>> RUN tar  xf buildx-linux-loong64.tar.gz
   7 |     
--------------------
ERROR: failed to solve: process "/bin/sh -c tar  xf buildx-linux-loong64.tar.gz" did not complete successfully: exit code: 2
```

该问题导致镜像构建失败，*严重影响了基于 docker-container驱动构建Docker 镜*像。

**新情况：在不使用docker-container驱动的情况下，物理机操作系统为OC，runc依赖的libseccomp版本为2.5.4时同样出现该问题**

***

## 二、复现场景

为排查问题，最小化复现环境。

Dockerfile

```
FROM lcr.loongnix.cn/library/debian:sid
RUN apt-get update && apt-get install -y wget tar
RUN wget http://cloud.loongnix.cn/releases/loongarch64/docker/buildx/0.12.0-rc1/buildx-linux-loong64.tar.gz
RUN tar  xf buildx-linux-loong64.tar.gz

```

使用docker默认的docker驱动构建此镜像时没有出现问题。

根据目前的线索可以判断问题是由buildkit镜像引起的，又根据buildkit的原理实际上是docker-in-docker，

因此可以怀疑的变量包括：1. buildkit二进制。2. buildkit的依赖项 runc及containerd。

设置三个对照场景

1. **LoongArch 架构 abi2.0**
   * 操作系统：alpine 3.21
   * 使用镜像：BuildKit 0.12.3-alpine
   * buildkit-runc 版本 1.1.7
   * 结果：出现上述解压错误
2. **LoongArch 架构 abi1.0**
   * 操作系统：Alpine 3.11
   * 使用镜像：BuildKit 0.12.3-alpine
   * buildkit-runc 版本 1.1.7
   * 结果：未出现错误
3. **x86 架构**
   * 操作系统：Alpine 3.22
   * 使用镜像：BuildKit stable
   * buildkit-runc 版本 1.2.6
   * 结果：解压操作正常，通过无错误

***

## 三、问题分析

1. **错误症状排查**
   * 初步观察到错误是在执行`tar xf buildx-linux-loong64.tar.gz`时触发的，错误提示无法更改文件权限（`Cannot change mode to rwxr-xr-x`），通常与系统调用权限或文件系统操作有关。
   * 在问题的排查过程中，推测问题可能源自**BuildKit 镜像**与**runc**之间的兼容性问题。为进一步确认问题的根源，采取了交叉验证的方式，测试了不同版本的 BuildKit 和 runc 在 ABI 2.0 系统上的表现。
     ### 交叉验证方法
     为了确定问题是出在 BuildKit 版本、runc 版本，还是二者之间的兼容性，我们选择了以下四个组别进行交叉验证：
     * **组别 1**：使用 BuildKit 0.12.3 版本，搭配 runc 1.1.7 版本。
     * **组别 2**：使用 BuildKit 0.12.3 版本，搭配 runc 1.2.6 版本。
     * **组别 3**：使用 BuildKit 0.19.0 版本，搭配 runc 1.1.7 版本。
     * **组别 4**：使用 BuildKit 0.19.0 版本，搭配 runc 1.2.6 版本。
       在 ABI 2.0 系统上，我们使用了这四个组别分别进行 BuildKit 镜像的构建测试，目的是验证在不同版本的 BuildKit 和 runc 组合下，构建过程的表现是否一致。
     ###### 测试结果
     * 在**组别 1**和**组别 2**中，使用**BuildKit 0.12.3 版本**，无论 runc 版本为 1.1.7 还是 1.2.6，**均出现了与解压 tar 时权限修改相关的错误**。
     * 在**组别 3**和**组别 4**中，使用**BuildKit 0.19.0 版本**，**无论 runc 版本为 1.1.7 还是 1.2.6，均编译通过**，没有出现权限修改错误。
       结果表明，主要问题出在runc，通过进一步排查以及相关资料查阅\[1]\[2]\[3]，可以发现在libseccomp这个runc的依赖项目下 2.5.5版本添加了一些针对内核6.3版本以上新增的系统调用的支持。且在2.5.4版本下出现了对arm、s390、riscv架构下fedora40版本 docker运行时的报错反馈。
2. **对比系统调用支持**
   * 进一步排查发现，新引入的系统调用引入了**fchmodat2**，用于支持更高级的权限修改操作。
   * 旧版本的`libseccomp`（低于 2.5.5 版本）并未支持 fchmodat2 系统调用，而 BuildKit 0.12.3 依赖的 runc(1.1.7) 使用的是 libseccomp低于2.5.5。
3. **依赖链问题**
   * runc 在启动容器时会加载 seccomp 策略以限制系统调用。由于低版本 libseccomp 未能识别或正确过滤 fchmodat2 的调用，导致 tar 在解压时尝试调用 fchmodat2 进行权限更改时失败，从而抛出 “Operation not permitted” 错误。
4. **问题定位总结**
   * 经过排查，可以确定：
     **低版本 libseccomp 不支持 fchmodat2 系统调用**
     → 旧版本 runc（依赖低版本 libseccomp）在 LoongArch 架构下执行 tar 命令时，因调用 fchmodat2 导致权限修改失败。

***

## 四、总结

**总结：**&#x901A;过交叉验证与系统调用支持的对比排查，我们确认了问题的根本原因在于旧版本 runc 依赖的 libseccomp 版本过低，无法支持新引入的 `fchmodat2` 系统调用，从而在 LoongArch 架构下构建 BuildKit 镜像时出现权限修改错误。建议升级 libseccomp 至 2.5.5 及以上版本，或采用新版 runc（如 1.2.6 及以上），以解决该问题。

***

## 附录

1. [libseccomp GitHub 仓库](https://github.com/seccomp/libseccomp)
2. [runc GitHub 仓库](https://github.com/opencontainers/runc)
3. [Docker BuildKit 官方文档](https://docs.docker.com/build/buildkit/)
4. https://github.com/seccomp/libseccomp/issues/406#issuecomment-1836895522
5. https://github.com/ocaml/infrastructure/issues/121
6. https://github.com/docker/docker-ce-packaging/issues/1012
7. 相关讨论及反馈：
   * 对于 ARM、s390、riscv 架构在 Fedora 40 下的报错反馈
   * https://bugzilla.redhat.com/show\\\_bug.cgi?id=2258631
   * https://github.com/docker/docker-ce-packaging/pull/1007
   * 内核 6.3 以上新增系统调用支持的更新说明
   * https://github.com/seccomp/libseccomp/pull/407/files
