# docker seccomp配置文件运行机制

# 一. 背景

&#x20;      该内容主要来自在debian系统上测试docker镜像时，发现在docker默认的seccomp配置文件中包含NUMA相关的系统调用，但是在容器中运行时却报get\_mempoliy权限问题。

`NUMA`概念

&#x20;      在传统的对称处理器(SMP)架构中，所有的处理器可以直接访问共享的全局内存，这种架构称为统一内存访问(UMA)。但随着处理器数量的增加和内存访问延迟的增加啊，UMA架构的性能可能会收到限制。

&#x20;       NUMA（非统一内存访问）是一种计算机内存架构，主要用于多处理器(特别是多核处理器)系统。在NUMA架构中，系统的内存被划分为多个节点，每个节点通常与一个处理器或一组处理器紧密相连，并提供高带宽访问。每个节点的内存对于本地处理器来说访问速度非常快，而远程节点的内存则较慢。

# 二.  运行环境

&#x20;    环境openeuler2203、openeuler2403、debian13

# 三.  测试用例

&#x20;      编写一个简单的测试用例来叙述该问题：

```
root@zxj:/home/debian/project/docker-pro/test-numa# cat Dockerfile 
#FROM debian:sid    #x86
FROM lcr.loongnix.cn/library/debian:sid 

# 安装需要的工具（例如，numactrl）
RUN apt-get update && apt-get install -y \
    numactl

## 检查是否允许 NUMA 操作
CMD ["numactl", "--show"]
```

&#x20;       生成镜像：

```
docker run -it numa-test .
```

&#x20;       LA上运行结果：

```
root@zxj:/home/debian/project/docker-pro/test-numa# docker run -it numa-test
get_mempolicy: Operation not permitted                                    
get_mempolicy: Operation not permitted
get_mempolicy: Operation not permitted
get_mempolicy: Operation not permitted
policy: default
preferred node: current
physcpubind: 0 1 2 3 
cpubind: 0 
nodebind: 0 
membind: 0 preferred: 
```

&#x20;      在上面的结果中打印出没有执行get\_mempolicy系统调用的权限。x86测试结果同上。

&#x20;      查看docker源码, 在moby/profiles/seccomp/defauil.json中有以下内容：

```
 57         "syscalls": [
...
785                 {
786                         "names": [        //包含限制的系统调用
787                                 "get_mempolicy",
788                                 "mbind",
789                                 "set_mempolicy",
790                                 "set_mempolicy_home_node"
791                         ],
792                         "action": "SCMP_ACT_ALLOW",      //允许系统调用执行
793                         "includes": {
794                                 "caps": [
795                                         "CAP_SYS_NICE"
796                                 ]
797                         }
798                 },
...
```

&#x20;       name: 包含了系统调用的名称；

&#x20;       action: SCMT\_ACT\_ALLOW表示允许这些系统调用通过，及docker容器中的进程可以执行这些系统调用；

&#x20;       includes: 定义了门开关。当进程具有CAP\_SYS\_NICE能力时，action中定义的行为才会生效。

&#x20;       CAP\_SYS\_NICE是一个linux能力，它允许进程更改调度策略、进程优先级或改变其他进程的优先级

&#x20;       通过上面的内容可以知道，在docker默认的seccomp配置文件中是允许get\_mempolicy、mbind等系统调用执行，但是受到门CAP\_SYS\_NICE的控制。

&#x20;      当在启动容器时通过--cap-add=sys\_nice后，此时容器便不会报权限问题：   

```
root@zxj:/home/debian/project/docker-pro/test-numa# docker run --cap-add=sys_nice  -it numa-test 
policy: default
preferred node: current
physcpubind: 0 1 2 3 
cpubind: 0 
nodebind: 0 
membind: 0 
preferred: 
```

&#x20;      ***此时可以得到结论：容器中没有CAP\_SYS\_NICE能力导致系统调用没有权限。***

# 四. 问题分析

&#x20;       根据上面的配置文件可知get\_mempolicy、mbind等系统调用执行，但是受到门CAP\_SYS\_NICE的限制，那会不会是启动的容器进程没有CAP\_SYS\_NICE能力导致这些系统调用无法使用。

&#x20;      根据网上搜索，可使用capsh工具来查看一个进程或bash具有哪些能力。故启动容器后查看该容器进程具有哪些能力：

```
# 安装capsh工具
apt install -y libcap2 libcap2-bin  
#查看启动容器进程的ID号
root@zxj:/home/debian/project/docker-pro/test-numa# ps -aux |grep numa-test
root      804830  0.0  0.1 1846464 27728 pts/3   Sl+  15:35   0:00 docker run -it numa-test
root      804919  0.0  0.0   6704  1616 pts/1    S+   15:36   0:00 grep numa-test
```

&#x20;        查看启动的容器进程所具有的linux能力：

```
root@zxj:/home/debian/project/docker-pro/test-numa# capsh --uid=804830 --print
Current: =
Bounding set =cap_chown,cap_dac_override,cap_dac_read_search,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_linux_immutable,cap_net_bind_service,cap_net_broadcast,cap_net_admin,cap_net_raw,cap_ipc_lock,cap_ipc_owner,cap_sys_module,cap_sys_rawio,cap_sys_chroot,cap_sys_ptrace,cap_sys_pacct,cap_sys_admin,cap_sys_boot,
cap_sys_nice,cap_sys_resource,cap_sys_time,cap_sys_tty_config,cap_mknod,cap_lease,cap_audit_write,cap_audit_control,cap_setfcap,cap_mac_override,cap_mac_admin,cap_syslog,cap_wake_alarm,cap_block_suspend,cap_audit_read,cap_perfmon,cap_bpf,cap_checkpoint_restore
Ambient set =
Current IAB: 
Securebits: 00/0x0/1'b0 (no-new-privs=0)
 secure-noroot: no (unlocked)
 secure-no-suid-fixup: no (unlocked)
 secure-keep-caps: no (unlocked)
 secure-no-ambient-raise: no (unlocked)
uid=804830(???) euid=804830(???)
gid=0(root)
groups=0(root)
Guessed mode: HYBRID (4)
```

&#x20;       Bounding set：进程能够修改或继承的最大能力集。

&#x20;      通过上面的内容启动的容器进程继承了cap\_sys\_nice的能力，但是为什么容器中仍然报get\_mempolicy没有权限？

&#x20;       最开始怀疑难道是docker在编译时没有使用profiles/seccomp/default.json文件吗，可是编译docker源码，但是在编译二进制dockerd时依赖到profiles/seccomp了，而且也查看docker官网https://docs.docker.com/engine/security/seccomp/   中给出的docker 默认的seccomp配置文件链接就是https://github.com/moby/moby/blob/master/profiles/seccomp/default.json 。那为什么容器进程继承了cap\_sys\_nice这个能力，可是仍然会报权限问题呢？

&#x20;      进一步思考Bounding set的这个功能是进程可以修改或者继承的最大能力集，因为容器的环境是隔离的，那会不会是在容器里面已经修改了cap\_sys\_nice这个能力？故在容器环境中执行capsh查看：

```
root@ca088395e77a:/# capsh --print
Current: cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap=ep
Bounding set =cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,cap_mknod,cap_audit_write,cap_setfcap
Ambient set =
Current IAB: !cap_dac_read_search,!cap_linux_immutable,!cap_net_broadcast,!cap_net_admin,!cap_ipc_lock,!cap_ipc_owner,!cap_sys_module,!cap_sys_rawio,!cap_sys_ptrace,!cap_sys_pacct,!cap_sys_admin,!cap_sys_boot,!cap_sys_nice,!cap_sys_resource,!cap_sys_time,!cap_sys_tty_config,!cap_lease,!cap_audit_control,!cap_mac_override,!cap_mac_admin,!cap_syslog,!cap_wake_alarm,!cap_block_suspend,!cap_audit_read,!cap_perfmon,!cap_bpf,!cap_checkpoint_restore
Securebits: 00/0x0/1'b0 (no-new-privs=0)
 secure-noroot: no (unlocked)
 secure-no-suid-fixup: no (unlocked)
 secure-keep-caps: no (unlocked)
 secure-no-ambient-raise: no (unlocked)
uid=0(root) euid=0(root)
gid=0(root)
groups=0(root)
Guessed mode: HYBRID (4)
```

&#x20;       Current:表示当前所拥有的能力，每个能力表示该进程允许执行的特定操作；

&#x20;       Bounding set：进程能够修改或继承的最大能力集；

&#x20;       Ambient set：进程在启动时所继承的能力；

&#x20;       Current IAB: 即使环境能力集，列出了进程当前不拥有的能力。**以！开头的能力表示该进程无法执行与这些能力相关的操作**；

&#x20;      uid和euid为0：表示进程的实际用户ID和有效用户ID都是root用户。

&#x20;      gid和groups为0：表示进程属于root组。

&#x20;     **此时可以发现，在容器内部是关闭了cap\_sys\_nice能力的，故在docker内部修改了这些能力集。**

# 五. 源码分析

&#x20;      在docker源码中搜索，在cli/contrib/completion/bash/docker文件中查看到以下内容：

&#x20;     通过798，799两行的注释可以知道从804～830的27个linux能力默认情况下未授予的，可以通过--cap-add来开启相关的linux能力（https://docs.docker.com/engine/reference/run/#/runtime-privilege-and-linux-capabilities）。

```
 798 # __docker_complete_capabilities_addable completes Linux capabilities which are
 799 # not granted by default and may be added.
 800 # see https://docs.docker.com/engine/reference/run/#/runtime-privilege-and-linux-capabilities
 801 __docker_complete_capabilities_addable() {
 802   local capabilities=(
 803                 ALL
 804                 CAP_AUDIT_CONTROL
 805                 CAP_AUDIT_READ
 806                 CAP_BLOCK_SUSPEND
 807                 CAP_BPF
 808                 CAP_CHECKPOINT_RESTORE
 809                 CAP_DAC_READ_SEARCH
 810                 CAP_IPC_LOCK
 811                 CAP_IPC_OWNER
 812                 CAP_LEASE
 813                 CAP_LINUX_IMMUTABLE
 814                 CAP_MAC_ADMIN
 815                 CAP_MAC_OVERRIDE
 816                 CAP_NET_ADMIN
 817                 CAP_NET_BROADCAST
 818                 CAP_PERFMON
 819                 CAP_SYS_ADMIN
 820                 CAP_SYS_BOOT
 821                 CAP_SYSLOG
 822                 CAP_SYS_MODULE
 823                 CAP_SYS_NICE
 824                 CAP_SYS_PACCT
 825                 CAP_SYS_PTRACE
 826                 CAP_SYS_RAWIO
 827                 CAP_SYS_RESOURCE
 828                 CAP_SYS_TIME
 829                 CAP_SYS_TTY_CONFIG
 830                 CAP_WAKE_ALARM
 831                 RESET
 832   )
 833         COMPREPLY=( $( compgen -W "${capabilities[*]} ${capabilities[*]#CAP_}" -- "$cur" ) ) 834 }
```

&#x20;      上面代码中的27个linux能力与容器进程中Current IAB显示的禁止的27个linux能力完成匹配。

&#x20;      在cli/contrib/completion/bash/docker文件的842～855行列出了默认情况下允许的14个linux能力：

```
 836 # __docker_complete_capabilities_droppable completes Linux capability options which are
 837 # allowed by default and can be dropped.
 838 # see https://docs.docker.com/engine/reference/run/#/runtime-privilege-and-linux-capabilities
 839 __docker_complete_capabilities_droppable() {
 840         local capabilities=(
 841                 ALL
 842                 CAP_AUDIT_WRITE
 843                 CAP_CHOWN
 844                 CAP_DAC_OVERRIDE
 845                 CAP_FOWNER
 846                 CAP_FSETID
 847                 CAP_KILL
 848                 CAP_MKNOD
 849                 CAP_NET_BIND_SERVICE
 850                 CAP_NET_RAW
 851                 CAP_SETFCAP
 852                 CAP_SETGID
 853                 CAP_SETPCAP
 854                 CAP_SETUID
 855                 CAP_SYS_CHROOT
 856                 RESET
 857         )
 858         COMPREPLY=( $( compgen -W "${capabilities[*]} ${capabilities[*]#CAP_}" -- "$cur" ) ) 859 }
```

&#x20;        这里的14个linux能力与容器中显示的Current 允许的14个linux能力完全匹配。 

&#x20;       **结论：宿主机中给启动的容器进程传递的linux能力是docker容器可继承或者修改的最大能力集，并不是docker容器中实际开启的linux能力，在docker源码中linux能力集进行的限制和允许。**

# 六. 扩展

## 6.1 docker seccomp配

在cli项目的docs/reference/commandline/container\_run.md文件中描述了seccomp的3个选项：

```
| --security-opt="seccomp=unconfined" | Turn off seccomp confinement for the container |
| --security-opt="seccomp=builtin" | Use the default (built-in) seccomp profile for the container. This can be used to enable seccomp for a container running on a daemon with a custom default profile set, or with seccomp disabled ("unconfined"). | 
| --security-opt="seccomp=profile.json" | White-listed syscalls seccomp Json file to be used as a seccomp filter |
```

&#x20;       \--security-opt="seccomp=unconfined" 禁用seccomp限制，这将关闭容器的seccomp隔离，容器可以执行任何系统调用，不受默认的seccomp配置；

&#x20;      \--security-opt="seccomp=builtin" 使用默认的seccomp配置文件；

&#x20;      \--security-opt="seccomp=profile.json"  使用指定的seccomp配置文件。

## 6.2 自定义seccomp配置文件

&#x20;        编写自定义的配置文件，如下：

```
root@zxj:/home/debian/project/docker-pro/test-numa# cat seccomp.json 
{
  "defaultAction": "SCMP_ACT_ALLOW",   //默认情况下允许所有系统调用
  "syscalls": [
    {
      "names": ["ptrace"],         //禁用ptrace系统调用
      "action": "SCMP_ACT_ERRNO"   //当调用指定的系统调用时将返回一个错误
    },
    {
      "names": ["chroot"],
      "action": "SCMP_ACT_ERRNO"  //禁用chroot系统调用
    }
  ]
}
```

&#x20;        在运行镜像时指定自定义的配置文件：

```
root@zxj:/home/debian/project/docker-pro/test-numa# docker run  --security-opt="seccomp=./seccomp.json"  -it numa-test
root@d60441e93ade:/# pwd
root@d60441e93ade:/# ls
bin  boot  dev	etc  home  lib	lib64  media  mnt  opt	proc  root  run  sbin  srv  sys  tmp  usr  var
root@d60441e93ade:/# cd /home/
root@d60441e93ade:/home# ls
root@d60441e93ade:/home# mkdir aaa
root@d60441e93ade:/home# chroot /home/aaa
chroot: cannot change root directory to '/home/aaa': Operation not permitted

root@79d3205424f3:/home# numactl --show
policy: default
preferred node: current
physcpubind: 0 1 2 3 
cpubind: 0 
nodebind: 0 
membind: 0 
preferred: 
```

&#x20;         此时可以看到在容器内部无法使用chroot，却可以正常使用numctl且没有get\_mempolicy的权限警告。    

# 七. 附录

## 7.1 **capsh**

capsh是一个用于查看和修改linux系统中进程能力的工具。通过capsh可以查看和修改进程的能力，控制进程可以执行哪些操作，即使该进程运行在非root用户下。

查看当前bash具有哪些能力：

```
sudo capsh --print
```

查看某个进程所拥有的能力：

```
sudo capsh --pid=<进程id> --print
```

## 7.2 **linux能力**

&#x20;      在linux中，能力是一种细粒度的权限控制机制，目的是替代传统的基于用户和组的权限模型。每个linux进程都可以被授予一组能力，以控制其可以执行的特定操作。能力被设计为分离了root用户权限中的一些敏感操作，允许非root用户执行这些操作，而不需要给予他们完全的root权限。

&#x20;      常见的linux能力：

&#x20;      CAP\_SYS\_NICE：允许进程修改其优先级和其他调度属性，如果一个进程拥有这个能力，它可以调整其他进程的优先级(包括增加CPU时间等)，因此对系统资源调度有更大的控制权。

&#x20;      CAP\_SYS\_ADMIN: linux最强大的能力之一，是超级用户权限的替代，具有此能力的进程可以执行几乎所有的系统管理任务，如挂载文件系统、修改内核参数、创建设备文件等。 

&#x20;      详细可见：\<u>https://www.cnblogs.com/hellokitty2/p/15224954.html\</u> 

## 7.3 **参考链接**

\<u>https://docs.docker.com/engine/containers/run/#/runtime-privilege-and-linux-capabilities\</u> 

\<u>https://www.cnblogs.com/hellokitty2/p/15224954.html\</u> 

\<u>https://docs.docker.com/engine/security/seccomp/\</u> 

\<u>https://github.com/kunpengcompute/kunpengcompute.github.io/issues/36\</u> 

 

[]()
