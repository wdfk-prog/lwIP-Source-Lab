# lwIP Source Lab

面向 **upstream lwIP `master` 源码阅读、Linux Host 网络实验、Wireshark 抓包与 GDB 调试** 的学习仓库。

这个仓库的目标不是堆 Demo，也不是把每个实验封装成“一键脚本”，而是把 lwIP 的真实实现按调用链拆开：

```text
Application
    ↓
Socket / Netconn / Raw API
    ↓
TCP / UDP
    ↓
IPv4 / ICMP
    ↓
ARP / Ethernet
    ↓
netif / pbuf
    ↓
Unix Port / tapif / sys_arch
    ↓
Linux TAP
```

每个阶段都遵循同一种学习方式：

```text
从入口函数开始
    ↓
确认初始化来源与核心对象
    ↓
沿真实 RX/TX 调用链阅读源码
    ↓
手工执行本阶段特殊命令
    ↓
Wireshark / tcpdump 观察线上报文
    ↓
GDB 检查对象、状态和 ownership
    ↓
把抓包现象与源码状态机互相验证
```

## 设计原则

### 只跟 upstream `master`

`upstream/lwip` 使用 Git submodule 指向官方仓库：

```text
https://github.com/lwip-tcpip/lwip.git
```

本项目不长期锁定 release tag。教程记录最近一次核对源码时的 SHA，但函数名、对象关系和调用链才是主要定位方式。

### 通用动作才写脚本

`scripts/` 只保留 5 个跨阶段复用的入口：

```text
scripts/
├── bootstrap-repository.sh   # 首次建立父仓库 + lwIP submodule
├── sync-upstream.sh          # 后续同步 upstream master
├── check-env.sh              # 通用 Host 环境检查
├── configure-debug.sh        # 刷新当前 master 配置并生成 Debug build tree
└── build.sh                  # example / unit / all 通用构建
```

阶段特殊动作不再包装成脚本，包括：

```text
TAP / veth / bridge 创建与清理
lwipcfg.h 阶段 override
tcpdump / Wireshark 抓包
Ping / netcat 流量生成
tc netem 故障注入
Stage 专用 GDB 断点
Unit Test suite 选择
SACK 专用 CMake build tree
```

这些命令直接写在教程里。学习网络栈时，网络配置和调试动作本身就是要理解的对象，不应该被脚本隐藏。

### build 不替你 configure

统一构建入口：

```sh
scripts/build.sh example
scripts/build.sh unit
scripts/build.sh all
```

`build.sh` **只负责构建**。如果 build tree 不存在，它会要求你先运行：

```sh
scripts/configure-debug.sh
```

这是刻意设计的。某些阶段会在 configure 之后手工追加 `lwipcfg.h` override；build 不能偷偷再次 configure，把实验配置覆盖掉。

## 首次开始

Ubuntu 建议先安装：

```sh
sudo apt update
sudo apt install \
  build-essential cmake ninja-build gdb check git pkg-config \
  iproute2 iputils-ping tcpdump wireshark tshark netcat-openbsd
```

然后：

```sh
scripts/check-env.sh
scripts/bootstrap-repository.sh
scripts/configure-debug.sh
scripts/build.sh all
```

后续更新源码：

```sh
scripts/sync-upstream.sh
scripts/configure-debug.sh
scripts/build.sh all
```

注意：`configure-debug.sh` 会重新从**当前 master** 的 `lwipcfg.h.example` 刷新本地 `lwipcfg.h`。进入某个网络实验 Stage 后，应先 configure，再按照对应教程手工追加该阶段 override，最后 build。

## 当前教程进度

| Stage | 教程 | 核心问题 |
|---:|---|---|
| 1 | [Linux Host 实验环境、源码地图与调试基线](docs/01-linux-lwip-lab.md) | upstream/submodule、Debug build、目录职责、GDB 基线 |
| 2 | [从 `main()` 到第一次 Ping](docs/02-netif-tap-first-ping.md) | TAP、`netif`、初始化链、ARP、IPv4、ICMP、RX/TX |
| 3 | [`pbuf` 数据结构、生命周期与 Chain](docs/03-pbuf.md) | `payload/len/tot_len/ref/next`、headroom、ownership |
| 4 | [Ethernet、ARP、IPv4 与 ICMP 深入](docs/04-ethernet-arp-ipv4-icmp.md) | EtherType 分流、Header remove/add、ARP cache、Echo Reply |
| 5 | [UDP Raw API](docs/05-udp-raw-api.md) | `udp_pcb`、bind、receive callback、UDP RX/TX |
| 6 | [Netconn 与 Socket API](docs/06-netconn-and-socket-api.md) | sequential API、Application Thread、Core Lock、Mailbox |
| 7 | [TCP 三次握手](docs/07-tcp-handshake.md) | LISTEN PCB、SYN/SYN-ACK/ACK、状态迁移 |
| 8 | [TCP 数据面](docs/08-tcp-data-path.md) | `unsent/unacked`、sequence、ACK、窗口、`tcp_write()` |
| 9 | [TCP 重传](docs/09-tcp-retransmission.md) | RTO、duplicate ACK、fast retransmit、`tc netem` |
| 10 | [TCP 乱序与 SACK](docs/10-tcp-out-of-order.md) | `ooseq`、overlap、gap fill、SACK bookkeeping |
| 11 | [`sys_arch` 与线程模型](docs/11-sys-arch.md) | pthread Port、mailbox、`tcpip_thread`、Core Locking |
| 12 | [`mem` / `memp` / `pbuf` 内存体系](docs/12-mem-memp-pbuf.md) | heap、typed pool、资源耗尽与统计 |

完整索引见 [docs/00-series-index.md](docs/00-series-index.md)。

## Stage 2 起使用的 Host 实验网络

默认实验网络采用：

```text
Linux Host : 198.18.0.1/24
TAP        : lwip0
lwIP       : 198.18.0.200/24
Gateway    : 198.18.0.1
```

使用 `198.18.0.0/24` 是为了避开常见家庭/办公 `192.168.x.x` 局域网。创建 TAP、配置静态地址、抓包和清理命令都明确写在教程 02 中。

## 当前仓库结构

```text
lwIP-Source-Lab/
├── .github/workflows/        # CI 与文档 Pages
├── .vscode/                  # 仅保留通用 build/debug 入口
├── docs/                     # Stage 1～12 教程
├── scripts/                  # 5 个通用脚本 + README
├── upstream/
│   └── lwip/                 # 官方 lwIP submodule
├── .gitmodules
├── mkdocs.yml
├── requirements-docs.txt
└── README.md
```

本地生成但不提交：

```text
build/
captures/
site/
```

## 关于 GDB

`.vscode/launch.json` 只保留两个通用入口：

```text
lwIP: unit tests (GDB)
lwIP: example_app (GDB)
```

各 Stage 的特殊环境变量、suite 选择和断点直接写在对应教程。例如：

```sh
CK_RUN_SUITE=PBUF CK_FORK=no \
  gdb ./build/unit-tests/lwip_unittests
```

或者：

```sh
PRECONFIGURED_TAPIF=lwip0 \
  gdb ./build/example/contrib/ports/unix/example_app/example_app
```

进入 GDB 后手工 `break` 对应入口函数。这样断点本身就是学习路径的一部分，而不是藏在 `debug/stage*.gdb` 中。

## 关于抓包

Linux 安装 Wireshark：

```sh
sudo apt install wireshark tshark tcpdump
```

保存 PCAP：

```sh
mkdir -p captures
sudo tcpdump -i lwip0 -nn -s 0 -U -w captures/example.pcap
```

打开：

```sh
wireshark captures/example.pcap
```

不同阶段使用不同 display filter，例如：

```text
arp || icmp
udp.port == 7
tcp.port == 7
tcp.analysis.retransmission || tcp.analysis.fast_retransmission
```

具体如何把 Wireshark 字段映射到 lwIP 结构体，在对应教程中展开。

## 阅读方法

不要从一个巨大 `.c` 文件第一行开始顺序阅读。

例如 TCP 阶段应当这样进入：

```text
example/app callback
    ↓
具体 public/core API
    ↓
PCB / pbuf / tcp_seg 状态变化
    ↓
input/output 核心函数
    ↓
netif
    ↓
tapif
    ↓
线上 packet
```

遇到条件编译时，先确认当前 example/Unit Test 的 `lwipopts.h`，再判断当前 binary 实际会走哪条分支。

## 验证边界

仓库中的命令是学习与手工实验入口。是否能在你的 Linux Host 上构建、运行、Ping、收发 UDP/TCP、触发 netem、命中 GDB 断点，应以你实际执行后的结果为准。

本项目把：

```text
源码结论
实验步骤
运行证据
```

明确区分，不用“文档里写了命令”替代真实运行证据。
