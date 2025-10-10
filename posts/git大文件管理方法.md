# git大文件管理方法

## 一、简介

Git LFS（Git Large File Storage）是由 GitHub 开发的一款 Git 扩展工具，旨在帮助开发者更高效地管理仓库中的大文件。传统 Git 会将文件的每个版本完整存储在仓库历史中，导致大文件快速膨胀仓库体积，当网络条件不富裕的时候会严重影响克隆和推送效率。Git LFS 通过以下机制解决这一问题：

#### 核心原理

1. **指针替换**：在提交时，将大文件替换为轻量级的文本指针（Pointer File），仅几 KB 大小，包含原文件的元信息（如哈希值、存储路径）。
2. **远程存储**：大文件实际内容被存储在 Git LFS 服务器（如 GitHub、GitLab 提供的服务，或自建服务器），与代码仓库分离。
3. **按需下载**：克隆或切换分支时，Git LFS 会根据指针文件从远程服务器下载当前需要的大文件版本，而非全部历史版本。

#### 工作流程

1. **安装**：先安装 Git LFS 客户端，并在仓库中初始化：(本次使用的环境为openeuler-24.03-lts-sp2)
   ```
   yum install git-lfs
   git lfs install
   ```
2. **跟踪文件**：指定需要使用 LFS 管理的文件类型或路径（支持通配符）：
   1. `git lfs track "*.mp4" # 跟踪所有 MP4 文件`
   2. `git lfs track "data/*" # 跟踪 data 目录下的所有文件`
   此操作会生成`.gitattributes`文件并自动提交，记录跟踪规则。
3. **正常提交**：添加、提交和推送文件时，Git LFS 会自动处理大文件：bash`git add video.mp4git commit -m "添加视频文件"git push origin main`推送时，大文件会上传至 LFS 服务器，代码仓库仅包含指针。
   ```
   git add video.mp4
   git commit -m "添加视频文件"
   git push origin main
   ```
4. **克隆仓库**：使用`git clone`时，LFS 文件会自动下载：
   1. `git clone https://example.com/repo.git`
   若只需代码而不下载大文件，可使用：

   `git lfs clone --skip-smudge https://example.com/repo.git`

   后续按需下载指定文件：bash`git lfs pull --include="video.mp4"`

#### 使用git lfs优势

* **仓库体积显著减小**：避免大文件占用过多空间，提升克隆速度。
* **版本控制更高效**：仅需管理轻量级指针，历史记录更清晰。
* **协作友好**：团队成员可选择性下载需要的大文件，节省带宽。
* **兼容性强**：与现有 Git 工作流程无缝集成，无需改变使用习惯。

## 二、Git LFS的使用过程

### 1.创建文件夹，使用git init

\# 在当前目录初始化一个新的 Git 仓库 git init

### 2.为用户初始化git lfs

```
[root@aa35c8357965 test]# git lfs install
Git LFS initialized.
```

验证

```
[root@aa35c8357965 test]# git lfs version
git-lfs/3.6.1 (GitHub; linux loong64; go 1.21.4)
```

### 3.**配置跟踪规则**

**命令行直接跟踪**

```
git lfs track "*.mp4"     # 跟踪所有 MP4 文件
git lfs track "data/*"    # 跟踪 data 目录下的所有文件
git lfs track "model.h5"  # 跟踪特定文件
```

执行后，Git LFS 会自动创建或更新`.gitattributes`文件（需提交该文件）。

```
$ git lfs track "*.zip"
```

### 4.**提交Git LFS配置文件，目标大文件和推送到运程的目标大文件**

添加、提交和推送文件的操作与普通 Git 流程一致，但大文件会自动上传到 LFS 服务器：

```
git add .gitattributes    # 提交跟踪规则
git add video.mp4        # 添加大文件（实际只提交指针）
git commit -m "添加视频文件"
git push origin main     # 推送时，大文件会上传到 LFS 服务器
```

#### （1）提交配置

```
$ git add .gitattributes
```

#### （2）查看大文件

```
$ ls -al
total 813758
drwxr-xr-x 1 28970 197609         0 Jul 27 10:24 ./
drwxr-xr-x 1 28970 197609         0 Jul 27 09:55 ../
drwxr-xr-x 1 28970 197609         0 Jul 27 10:27 .git/
-rw-r--r-- 1 28970 197609        43 Jul 27 10:24 .gitattributes
-rw-r--r-- 1 28970 197609 833276817 Jul 16 22:16 MDK528.zip
-rw-r--r-- 1 28970 197609        39 Jul 27 09:45 README.md
```

#### （3）暂存目标大文件

```
$ git add MDK528.zip
```

#### （4）提交到本地

```
$ git commit -m "Firstly,commit a big MDK_Setup_package."
```

### (5)推送至远程

```
$ git push origin main
```
