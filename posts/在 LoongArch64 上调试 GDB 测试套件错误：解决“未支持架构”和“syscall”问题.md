# 引言

在 LoongArch64 系统上运行 GDB 测试套件时，我在执行 gdb.threads/step-over-thread-exit-while-stop-all-threads.exp 等测试用例时遇到了编译错误。错误源于 my-syscalls.S 汇编文件，最初报错为“未支持架构”（Unsupported architecture），在添加 LoongArch 支持后，又出现了无法识别 syscall 指令的错误。本文详细记录了问题的原因、解决步骤，以及对 LoongArch 指令集和系统调用处理的深入分析。

# 问题描述

在运行 GDB 测试套件时，出现了以下错误：
```
Running /home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/gdb.threads/step-over-thread-exit-while-stop-all-threads.exp ...
gdb compile failed, /home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/lib/my-syscalls.S:67:3: error: #error "Unsupported architecture"
   67 | # error "Unsupported architecture"
      |   ^~~~~
```
在修改 my-syscalls.S 添加 LoongArch 支持后，出现了新的错误：
```
gdb compile failed, /home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/lib/my-syscalls.S:81: Error: no match insn: syscall
/home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/lib/my-syscalls.S:85: Error: no match insn: syscall
```
这些错误表明存在两个问题：


汇编器（as）最初无法识别 LoongArch 架构，触发了 #error "Unsupported architecture" 指令。

添加 LoongArch 支持后，汇编器无法识别 syscall 指令，表明工具链支持不完整。

# 背景：my-syscalls.S 文件

GDB 测试套件中的 my-syscalls.S 文件为需要精确控制系统调用指令的测试提供包装函数。它定义了一个 SYSCALL 宏，用于为不同架构生成类似 my_execve（系统调用号 221）和 my_exit（系统调用号 93）的函数，支持 x86_64、i386、aarch64 等架构。在我的案例中，需要为 LoongArch64 添加支持。

原始文件中缺少 LoongArch 分支，导致“未支持架构”错误。在添加 LoongArch 支持后，syscall 指令问题暴露了工具链的局限性。

## 问题原因分析

1. “未支持架构”错误

初始错误是因为 my-syscalls.S 文件的预处理器条件中未处理 __loongarch64：

#if defined(__x86_64__)
  /* x86_64 系统调用代码 */
#elif defined(__i386__)
  /* i386 系统调用代码 */
#elif defined(__aarch64__)
  /* aarch64 系统调用代码 */
#else
# error "Unsupported architecture"
#endif

由于未定义或处理 __loongarch64，汇编器触发了 #error 指令。这需要为 LoongArch 添加特定分支。

2. syscall 指令错误

在添加以下 LoongArch 宏后：

#elif defined(__loongarch64)
/* LoongArch 64-bit syscall wrapper */
#define SYSCALL(NAME, NR)       \
.global NAME                    ;\
NAME:                           ;\
        ori $a7, $zero, NR      ;\
        /* $a0-$a2 assumed to contain arguments */ \
NAME ## _syscall:               ;\
        syscall 0               ;\
        jr $ra

汇编器在第 81 行和第 85 行（对应 my_execve 和 my_exit 的 syscall 0）报错 no match insn: syscall。这表明：





工具链问题：GNU 汇编器（as）版本可能过旧（例如 < 2.39），不支持 LoongArch 的 syscall 指令（机器码 0x002b0000）。



架构配置错误：汇编器可能未以 LoongArch64 模式运行，导致无法识别特定指令。



语法敏感性：虽然 syscall 0 是正确语法，但旧版汇编器可能对语法解析有问题。

3. 为什么避免使用 li 和 addi.w

最初，我尝试使用 li 伪指令加载系统调用号到 $a7：

li $a7, NR

这导致错误（no match insn: li $a7, 221），因为旧版 binutils 不支持 LoongArch 的 li 伪指令。我也考虑过 addi.w，但它不适合：

立即数限制：addi.w 只支持 12 位有符号立即数（-2048 到 +2047），无法处理较大的系统调用号。

初始值依赖：addi.w $a7, $a7, NR 需要 $a7 预先初始化（例如为 0），增加了复杂性。


符号扩展：addi.w 会将结果符号扩展到 64 位，可能导致高位错误设置（系统调用号应为无符号整数）。

因此，我选择了 ori $a7, $zero, NR，它直接从零寄存器（$zero）加载 12 位无符号立即数（0 到 4095），适用于小的系统调用号（如 221 和 93）。

# 解决方案

步骤 1：更新 binutils 到最新版本

syscall 指令错误很可能是由于 binutils 版本过旧。LoongArch 的支持在 binutils 2.39 及以上版本得到显著改进，推荐使用 2.41。


检查当前汇编器版本：

as --version

如果版本低于 2.41，更新 binutils：

wget https://sourceware.org/pub/binutils/releases/binutils-2.41.tar.gz
tar -xzf binutils-2.41.tar.gz
cd binutils-2.41
./configure --target=loongarch64-unknown-linux-gnu
make
sudo make install



# 验证新版本：

/usr/local/bin/as --version



# 重新构建 GDB：

cd /home/yzw/binutils-gdb
make clean
./configure --target=loongarch64-unknown-linux-gnu
make

# 步骤 2：修改 my-syscalls.S

为解决“未支持架构”和 syscall 问题，更新 my-syscalls.S 文件，添加 LoongArch 特定宏。对于小的系统调用号（221 和 93），单条 ori 指令足够：

#elif defined(__loongarch64)
/* LoongArch 64-bit syscall wrapper */
#define SYSCALL(NAME, NR)       \
.global NAME                    ;\
NAME:                           ;\
        ori $a7, $zero, NR      ;\
        /* $a0-$a2 assumed to contain arguments */ \
NAME ## _syscall:               ;\
        syscall 0               ;\
        jr $ra

为支持更大的系统调用号，可使用 lu12i.w 和 ori 的组合：

#elif defined(__loongarch64)
/* LoongArch 64-bit syscall wrapper */
#define SYSCALL(NAME, NR)       \
.global NAME                    ;\
NAME:                           ;\
        lu12i.w $a7, NR >> 12   ;\
        ori $a7, $a7, NR & 0xfff ;\
        /* $a0-$a2 assumed to contain arguments */ \
NAME ## _syscall:               ;\
        syscall 0               ;\
        jr $ra





lu12i.w $a7, NR >> 12：将 NR 的高 20 位（右移 12 位）加载到 $a7 的位 [31:12]，低 12 位清零。



ori $a7, $a7, NR & 0xfff：将 NR 的低 12 位填充到 $a7 的位 [11:0]。

# 步骤 3：确保正确架构

确保汇编器以 LoongArch64 模式运行：

as -march=loongarch64 -o my-syscalls.o my-syscalls.S

或者，在 my-syscalls.S 文件顶部添加：

.arch loongarch64

# 步骤 4：重新运行测试

重新运行测试套件：

cd /home/yzw/binutils-gdb/build/gdb/testsuite
runtest /home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/gdb.threads/step-over-thread-exit-while-stop-all-threads.exp

如果错误仍未解决，启用调试日志：

runtest --debug /home/yzw/binutils-gdb/build/gdb/testsuite/../../../gdb/testsuite/gdb.threads/step-over-thread-exit-while-stop-all-threads.exp

检查 gdb.sum 和 gdb.log 文件以获取详细错误信息。

# 步骤 5：临时绕过方案

如果无法立即更新 binutils，可将 syscall 0 替换为机器码：

.word 0x002b0000

这绕过了汇编器的问题，但因可读性差，不建议长期使用。

# 技术洞察：加载系统调用号

为什么使用 ori $a7, $zero, NR？

对于小的系统调用号（例如 221 或 93）：


立即数范围：ori 支持 12 位无符号立即数（0 到 4095），覆盖大多数 Linux 系统调用号。


无依赖性：使用 $zero 确保结果精确为 NR，无需依赖 $a7 的初始值。



高效性：仅需一条指令，相比 lu12i.w + ori 的两指令方案更简洁。

理解 lu12i.w 和 ori

对于较大的系统调用号（例如 4096 = 0x1000）：


二进制表示：00000000000000000001000000000000

高 20 位（位 [31:12]）：00000000000000000001（NR >> 12 = 1）

低 12 位（位 [11:0]）：000000000000（NR & 0xFFF = 0）

执行过程：

lu12i.w $a7, 1：将位 [31:12] 设置为 0x1000（1 << 12 = 4096），低 12 位清零。

ori $a7, $a7, 0：保持值不变（4096）。

结果：$a7 = 4096。

此方法支持任意 32 位系统调用号。

# 经验教训

工具链兼容性：LoongArch 是较新的架构，需使用最新 binutils（2.41 或更高）以确保完整指令支持。

指令选择：对于小立即数，使用 ori 高效；对于通用场景，lu12i.w + ori 更稳健。

架构指定：使用 -march=loongarch64 或 .arch loongarch64 确保正确解析指令。

调试技巧：启用 runtest --debug 并分析 gdb.sum 和 gdb.log 以获取详细错误信息。

# 结论

LoongArch64 上的 GDB 测试套件错误源于过旧的 binutils 版本和 my-syscalls.S 中缺少 LoongArch 支持。通过更新 binutils 到 2.41、添加适当的 LoongArch SYSCALL 宏并确保正确架构模式，问题得以解决。这次经历强调了为新架构保持更新工具链的重要性。

如果你在 LoongArch 或其他架构上遇到类似问题，请检查工具链版本，单独测试汇编文件，或考虑临时使用机器码绕过。欢迎在评论区分享你的经验或问题！
