# buildx-qemu-user + cross-gdb 调试记录

背景：

euler2403 docker buildx 不可用



结论：

x86默认4K对齐，LA默认16K对齐。



# 测试用例及构建命令

```
main.c:
int main() {}

cmd:
gcc main.c -o main_sepol -lsepol
```

# 动态库加载

dl\_main -> dl\_map\_objects: 根据文件名映射动态对象。

\_dl\_map\_object\_deps：加载已映射对象的依赖对象。

### 先 加载可执行文件

```
#0  _dl_map_segments (loader=0x0, has_holes=false, maplength=16408, nloadcmds=4, loadcmds=0x7fffffffd860, type=2, header=0x7fffffffde38, fd=3, l=0x7ffff7ffe2d0) at ./dl-map-segments.h:83
#1  _dl_map_object_from_fd (name=0x7fffffffe7da "./main_sepol", origname=0x0, fd=3, fbp=0x7fffffffde30, realname=0x7ffff7ffe2c0 "./main_sepol", loader=0x0, l_type=0, mode=536870912,
    stack_endp=0x7fffffffde20, nsid=0) at dl-load.c:1260
#2  0x00007ffff7fd49fb in _dl_map_object (loader=0x0, name=0x7fffffffe7da "./main_sepol", type=0, trace_mode=0, mode=536870912, nsid=0) at dl-load.c:2254
#3  0x00007ffff7feaa59 in dl_main (phdr=<optimized out>, phnum=<optimized out>, user_entry=<optimized out>, auxv=<optimized out>) at rtld.c:1590
#4  0x00007ffff7fe82f3 in _dl_sysdep_start (start_argptr=start_argptr@entry=0x7fffffffe5d0, dl_main=dl_main@entry=0x7ffff7fe9b10 <dl_main>) at ../sysdeps/unix/sysv/linux/dl-sysdep.c:140
#5  0x00007ffff7fe9914 in _dl_start_final (arg=0x7fffffffe5d0) at rtld.c:497
#6  _dl_start (arg=0x7fffffffe5d0) at rtld.c:582#7  0x00007ffff7fe88c8 in _start ()
```

### 后 加载依赖库

```
#0  _dl_map_segments (loader=0x7ffff7ffe2d0, has_holes=false, maplength=761480, nloadcmds=4, loadcmds=0x7fffffffd250, type=3, header=0x7fffffffd7b8, fd=3, l=0x7ffff7fc50c0)
    at ./dl-map-segments.h:83
#1  _dl_map_object_from_fd (name=0x4004b0 "libsepol.so.2", origname=0x0, fd=3, fbp=0x7fffffffd7b0, realname=0x7ffff7fc50a0 "/usr/lib64/libsepol.so.2", loader=0x7ffff7ffe2d0, l_type=1, mode=0,
    stack_endp=0x7fffffffd7a0, nsid=0) at dl-load.c:1260
#2  0x00007ffff7fd49fb in _dl_map_object (loader=0x7ffff7ffe2d0, name=0x4004b0 "libsepol.so.2", type=1, trace_mode=0, mode=0, nsid=0) at dl-load.c:2254
#3  0x00007ffff7fcf2a5 in openaux (a=a@entry=0x7fffffffddb0) at dl-deps.c:64
#4  0x00007ffff7fce0e1 in __GI__dl_catch_exception (exception=exception@entry=0x7fffffffdd90, operate=operate@entry=0x7ffff7fcf270 <openaux>, args=args@entry=0x7fffffffddb0) at dl-catch.c:237
#5  0x00007ffff7fcf6f2 in _dl_map_object_deps (map=map@entry=0x7ffff7ffe2d0, preloads=preloads@entry=0x0, npreloads=npreloads@entry=0, trace_mode=<optimized out>, open_mode=open_mode@entry=0)
    at dl-deps.c:232
#6  0x00007ffff7feb342 in dl_main (phdr=<optimized out>, phnum=<optimized out>, user_entry=<optimized out>, auxv=<optimized out>) at rtld.c:1973
#7  0x00007ffff7fe82f3 in _dl_sysdep_start (start_argptr=start_argptr@entry=0x7fffffffe5d0, dl_main=dl_main@entry=0x7ffff7fe9b10 <dl_main>) at ../sysdeps/unix/sysv/linux/dl-sysdep.c:140
#8  0x00007ffff7fe9914 in _dl_start_final (arg=0x7fffffffe5d0) at rtld.c:497
#9  _dl_start (arg=0x7fffffffe5d0) at rtld.c:582#10 0x00007ffff7fe88c8 in _start ()
```

### loadcmds 参数

该参数的作用就是从加载文件中获取PT\_LOAD部分内容，后续传递给加载器，以进行具体的映射。

```
struct loadcmd
{
  ElfW(Addr) mapstart, mapend, dataend, allocend, mapalign;
  ElfW(Off) mapoff;
  int prot; // 权限域
};

重点的，mapalign, 4K很常见，但是LA目前主要还是16K。

PT_LOAD 是一种程序头类型，指该segment是可加载的。相关的内容会从文件加载到内存中。
```

```
p *loadcmds$5 = {mapstart = 0, mapend = 1859584, dataend = 1855719, allocend = 1855719, mapalign = 4096, mapoff = 0, prot = 5}
```

### 修改验证

```
(gdb) set loadcmds.mapalign = 0x4000
(gdb) p *loadcmds$14 = {mapstart = 0, mapend = 1859584, dataend = 1855719, allocend = 1855719, mapalign = 16384, mapoff = 0, prot = 5}

或者修改mapend进行验证，亦可说明是页对齐导致的mmap分配错误。
```

同时，也可借助readelf工具查看libsepol,.so的对齐情况：

```
Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  LOAD           0x0000000000000000 0x0000000000000000 0x0000000000000000
                 0x0000000000007650 0x0000000000007650  R      0x1000
  LOAD           0x0000000000008000 0x0000000000008000 0x0000000000008000
                 0x0000000000083ce9 0x0000000000083ce9  R E    0x1000
  LOAD           0x000000000008c000 0x000000000008c000 0x000000000008c000
                 0x00000000000297e8 0x00000000000297e8  R      0x1000
  LOAD           0x00000000000b5ff0 0x00000000000b6ff0 0x00000000000b6ff0                 0x0000000000001140 0x0000000000002e98  RW     0x1000
```

# qemu-gdb 调试

```
./qemu-x86_64 -L /usr/x86_64-linux-gnu/ -g 1234 ~/main_sepol
qemu-user 需要使能gdb调试: --enable-debug

./gdb/gdb ~/main_sepol   // 这里的gdb是交叉构建出来的，configure使能target=x86_64-linux-gnu即可
target remote localhost:1234
```



