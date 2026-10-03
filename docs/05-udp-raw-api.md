<meta name="referrer" content="no-referrer" />

# 教程 05：从 `udpecho_raw_init()` 到 Echo Reply——UDP Raw API、PCB 与回调数据通路

> 摘要：从 UDP 数据报与端口分发模型出发，沿 Raw API 真实入口追踪 PCB 建立、接收匹配、回调、回包与 pbuf ownership。

[TOC]

UDP（User Datagram Protocol，用户数据报协议）是 IP 之上的无连接传输协议。它把应用一次提交的一条消息作为一个 **datagram（数据报）**发送，并在接收端保留这条消息的边界；UDP 自身不先建立连接，也不保证可靠到达、顺序或自动重传。[S4](#source-s4)[S6](#source-s6) 本篇从 upstream Raw UDP Echo 的真实入口出发，重点回答：一个发往 UDP port 7 的 datagram，怎样被 `udp_pcb` 匹配、交给回调，再沿同一 PCB 发回发送端。

Stage 4 已经走到 `ip4_input()` 的上层协议分发。本篇只改变一个关键字段：IPv4 Header 的 `Protocol` 为 `17` 时，payload 交给 UDP；Ethernet、ARP 与 IPv4 前半段不再重复展开。[S3](#source-s3)[S4](#source-s4)

## 阅读源码前：建议提前阅读

下面资料用于提前建立规范和 API 位置感，不是继续阅读正文的强制条件：

1. [RFC 768 — User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html)：重点看 UDP Header，以及 Source Port（源端口）、Destination Port（目标端口）、Length（UDP Header + payload 总长度）、Checksum（校验字段）四个字段。[S4](#source-s4)
2. [lwIP 2.1.x — UDP Raw API](https://www.nongnu.org/lwip/2_1_x/group__udp__raw.html)：用于先认识 `udp_new()`、`udp_bind()`、`udp_recv()` 与 `udp_sendto()` 这些公开 API；本文的源码事实仍以固定 commit 为准。[S8](#source-s8)
3. [IANA — Service Name and Transport Protocol Port Number Registry](https://www.iana.org/assignments/service-names-port-numbers?search=echo)：用于确认示例使用的 UDP port 7 注册名为 `echo`。[S7](#source-s7)
4. [Cloudflare — 什么是 UDP？](https://www.cloudflare.com/zh-cn/learning/ddos/glossary/user-datagram-protocol-udp/)：第一次接触 UDP 时，可用于快速理解“无连接、datagram、可靠性由上层决定”的整体边界。[S6](#source-s6)

## 先建立 UDP Echo 的协议模型

### Datagram、endpoint 与 port 分别是什么

UDP 的基本数据单位是 **datagram**。一个 datagram 由 8-byte UDP Header 加应用 payload 组成；`Length` 表示 UDP Header 与 payload 的总长度，`Checksum` 用于检测传输中的数据损坏。[S4](#source-s4)

UDP **endpoint（端点）**可以理解为“IP 地址 + UDP port”。Port 是 UDP Header 中的 16-bit 端口号，用来把到达同一台主机的 datagram 分发给不同应用端点。对本例最重要的是方向：

| UDP Header 字段 | 谁填写 | 接收端如何使用 |
| --- | --- | --- |
| Source Port | 发送端 | 回包时作为目标 port；若 PCB 绑定了特定远端 endpoint，还会参与远端匹配 |
| Destination Port | 发送端 | 选择本地 UDP endpoint；本例最终匹配 `pcb->local_port == 7` |
| Length | 发送端 | 描述当前 UDP datagram 的总长度 |
| Checksum | 发送端 | 校验 UDP 伪首部（由 IP 源/目标地址、协议号等组成且不作为额外字节在线上传输）、UDP Header 与 payload；当前正文只关注 lwIP 在 RX/TX 路径中的验证与生成位置 |

这里的 **PCB（Protocol Control Block，协议控制块）**是 lwIP Core 保存一个协议端点运行时状态的对象。UDP 的 `struct udp_pcb` 记录 local/remote IP、local/remote port、flags 和接收 callback；它不是 packet buffer，也不是 Socket API 的整数 fd。[S2](#source-s2)

**`pbuf`（packet buffer）**是 Stage 3 已经建立的 packet 数据与元数据容器；本篇只关心 UDP 如何改变 `p->payload` 的数据视图以及 callback 最终由谁释放 RX `pbuf`。

### 为什么 UDP Echo 不需要三次握手

UDP 是无连接协议。Host 不需要先和 lwIP 建立 UDP connection，就可以直接发送 datagram。假设 Host 使用一个临时源端口 `53000`，目标是 `198.18.0.200:7`：

```text
Host endpoint              lwIP Echo endpoint
198.18.0.1:53000  ------>  198.18.0.200:7
                    UDP datagram
```

IPv4 层先根据 `Protocol = 17` 把 payload 交给 UDP；UDP 再根据 Destination Port、目标 IP 以及 PCB 的连接属性选择接收 PCB。Echo callback 收到 payload 后，以原 packet 的 Source IP/Source Port 作为回包目标，因此 Echo Reply 返回 `198.18.0.1:53000`。[S2](#source-s2)[S3](#source-s3)

这条最小成功交互可以先画成纯协议流程：

```mermaid
sequenceDiagram
    participant H as Host 198.18.0.1:53000
    participant U as lwIP UDP endpoint 198.18.0.200:7

    H->>U: UDP datagram, SrcPort=53000, DstPort=7
    Note over U: 按目标 IP/port 匹配 PCB，移除 UDP Header
    U-->>H: UDP Echo Reply, SrcPort=7, DstPort=53000
```

### 协议动作怎样映射到 lwIP 源码

| 协议阶段 | 协议对象/动作 | lwIP 实现位置 | 关键对象 | 完成后的下一步 |
| --- | --- | --- | --- | --- |
| 建立本地端点 | 绑定本地 UDP port 7 | `udp_new_ip_type()` → `udp_bind()` | `struct udp_pcb` | 注册 RX callback |
| 等待 datagram | 保存接收处理函数 | `udp_recv()` | `pcb->recv` / `recv_arg` | packet 到达后由 Core 调用 |
| IPv4 分发 | `Protocol = 17` | `ip4_input()` → `udp_input()` | RX `pbuf` | 解析 UDP Header |
| UDP 分发 | Destination Port / IP / connected 条件匹配 | `udp_input()` | `udp_pcbs` 链表 | 选出接收 PCB |
| 应用接收 | payload 交给 Echo callback | `pcb->recv()` → `udpecho_raw_recv()` | RX `pbuf` | 调用 `udp_sendto()` |
| Echo TX | 构造新的 UDP Header 并进入 IP output | `udp_sendto()` | 同一 RX payload + TX Header | 返回 Host 后释放 RX pbuf 引用 |

下面进入真实入口 `udpecho_raw_init()`，并按这张表的执行顺序逐步下钻。

## 1. Raw API 的第一个真实入口：`udpecho_raw_init()`

upstream Raw UDP Echo 的初始化代码很短：[S1](#source-s1)

```c
udpecho_raw_pcb = udp_new_ip_type(IPADDR_TYPE_ANY);
if (udpecho_raw_pcb != NULL) {
  err = udp_bind(udpecho_raw_pcb, IP_ANY_TYPE, 7);
  if (err == ERR_OK) {
    udp_recv(udpecho_raw_pcb, udpecho_raw_recv, NULL);
  }
}
```

这三步分别建立三类状态：

```mermaid
flowchart LR
    A["udp_new_ip_type()"] --> B["分配 UDP PCB"]
    B --> C["udp_bind(..., 7)"]
    C --> D["PCB 绑定本地 port 7"]
    D --> E["udp_recv(callback)"]
    E --> F["保存 RX callback + callback arg"]
```

前面的协议模型已经定义 PCB。进入实现后，这个抽象具体落在 `struct udp_pcb`，其中保存 local/remote IP、port、flags 和接收 callback 等状态。[S2](#source-s2)

再次把三个容易混淆的对象放在一起：

| 对象 | 生命周期 | 主要内容 |
| --- | --- | --- |
| `struct udp_pcb` | UDP endpoint 生命周期 | 地址、端口、flags、callback |
| `struct pbuf` | 单个 packet 生命周期 | packet bytes + ownership |
| Linux/socket fd | Socket API 才出现 | application-facing descriptor |

Raw API 直接操作 PCB，所以应用代码必须遵守 lwIP Core 的线程上下文和 callback ownership 规则。

## 2. `udp_new_ip_type()`：PCB 从哪里来

`udp_new()`/`udp_new_ip_type()` 最终从 `MEMP_UDP_PCB` 固定对象池申请 `struct udp_pcb`，初始化后挂进 UDP PCB 管理体系。[S2](#source-s2)

这和 Stage 3 的 `PBUF_POOL` 是两种完全不同的 pool：

- `MEMP_UDP_PCB`：固定大小的协议控制对象；
- `MEMP_PBUF_POOL`：固定大小的 packet buffer。

一个 UDP endpoint 可以连续接收很多 pbuf，但通常只对应一个长期存在的 PCB。

## 3. `udp_bind()`：把标准 UDP Destination Port 映射成 PCB 条件

`udp_bind(pcb, IP_ANY_TYPE, 7)` 把 PCB 的 local endpoint 配置成“任意本地地址 + UDP port 7”。[S2](#source-s2) IANA 注册表中 port 7 的 UDP service name 是 `echo`，这正是 upstream 示例选择该端口的背景。[S7](#source-s7)

在前面的协议模型里，Destination Port 负责选择接收端点；在 lwIP 中，这个标准语义进一步落实为 `udp_input()` 对 `pcb->local_port` 的匹配条件。

## 4. `udp_recv()` 并不收包，它只是注册 callback

`udp_recv(pcb, udpecho_raw_recv, NULL)` 把函数指针和 callback argument 保存到 PCB。[S2](#source-s2)

这一点必须和真正的 RX 事件分开：

```text
初始化阶段
  udp_recv()
  只建立 callback binding

运行阶段
  packet 到达
  udp_input() 匹配 PCB
  才调用 pcb->recv(...)
```

Raw API 是 callback 模型，不是“应用线程阻塞在 recv()”模型。Stage 6 的 Netconn 会专门改变这一点。

## 5. 一个 UDP datagram 怎样走到 `udp_input()`

到这里完成的是协议总流程中的“本地 endpoint 已建立并注册 callback”。现在协议从初始化阶段转入 RX：Host 真正发送 datagram，下面继续追它怎样进入 UDP Core。

Host 发送到 `198.18.0.200:7` 后，前半段仍然是：[S3](#source-s3)

```text
TAP -> pbuf
    -> tcpip_input()
    -> tcpip_thread
    -> ethernet_input()
    -> ip4_input()
```

`ip4_input()` 看到：

```text
Protocol = 17
```

于是移除 IPv4 Header 后调用 `udp_input()`。[S3](#source-s3)

进入 `udp_input()` 时：

```text
p->payload -> UDP Header
```

## 6. `udp_input()` 到底怎样找到应该调用哪个 PCB callback

前面的协议模型已经说明 UDP Header 的四个字段。进入 `udp_input()` 后，当前分发首先依赖 Source Port 与 Destination Port；下面直接看这两个字段怎样进入 PCB 匹配。[S4](#source-s4)

这里最容易产生一个实现层误解：**不是 TAP RX thread 自己拿 UDP Destination Port 去找 callback。** 当前 `LWIP_TCPIP_CORE_LOCKING_INPUT=0` 路径中，TAP/driver RX context 只负责把 `pbuf` 经 `tcpip_input()` 投递进 `tcpip_mbox`；真正运行 `ethernet_input() -> ip4_input() -> udp_input()` 的是 `tcpip_thread`。[S3](#source-s3)

因此本节讨论的 PCB 查找实际发生在：

```mermaid
flowchart TD
    A["TAP RX context<br/>read frame"] --> B["tcpip_input()"]
    B --> C["TCPIP_MSG_INPKT -> tcpip_mbox"]
    C --> D["tcpip_thread"]
    D --> E["ethernet_input()"]
    E --> F["ip4_input()"]
    F -->|"Protocol = UDP"| G["udp_input()"]
    G --> H["遍历 udp_pcbs"]
```

### 6.1 `udp_input()` 先读取 UDP Source/Destination Port

进入 `udp_input()` 时，Stage 4 的 IPv4 Header 已经移除，`p->payload` 指向 UDP Header。继续阅读 `udp_input()` 的上游连续源码片段：[S2](#source-s2)

```c
udphdr = (struct udp_hdr *)p->payload;

/* is broadcast packet ? */
broadcast = ip_addr_isbroadcast(ip_current_dest_addr(), ip_current_netif());

/* convert src and dest ports to host byte order */
src = lwip_ntohs(udphdr->src);
dest = lwip_ntohs(udphdr->dest);
```

对接收方来说两个 port 的方向必须分清：

```text
packet Source Port      -> 远端端口 -> 后面与 pcb->remote_port 比较
packet Destination Port -> 本地端口 -> 后面与 pcb->local_port 比较
```

例如 Host 发往 Raw Echo：

```text
Host      198.18.0.1:53000
              |
              v
lwIP      198.18.0.200:7
```

进入 lwIP 的 packet 中：

```text
src  = 53000
dest = 7
```

所以最先决定“哪个本地 UDP endpoint 有资格接收”的是 **Destination Port 对 `pcb->local_port`**，不是拿 packet Source Port 去匹配 local port。

### 6.2 当前实现就是线性 `for` 遍历 `udp_pcbs` 链表

继续阅读 `udp_input()`。当前实现没有用 hash table 按 port O(1) 查找，而是从全局 `udp_pcbs` 链表头开始逐项遍历：[S2](#source-s2)

```c
pcb = NULL;
prev = NULL;
uncon_pcb = NULL;
/* Iterate through the UDP pcb list for a matching pcb.
 * 'Perfect match' pcbs (connected to the remote port & ip address) are
 * preferred. If no perfect match is found, the first unconnected pcb that
 * matches the local port and ip address gets the datagram. */
for (pcb = udp_pcbs; pcb != NULL; pcb = pcb->next) {
```

所以回答“是不是 `for` 循环遍历 PCB 链表”就是：**是。** 但匹配条件并不只有一个 port。

继续阅读 `udp_input()`：第一层先比较本地 endpoint。[S2](#source-s2)

```c
/* compare PCB local addr+port to UDP destination addr+port */
if ((pcb->local_port == dest) &&
    (udp_input_local_match(pcb, inp, broadcast) != 0)) {
```

这里包含：

```text
packet Destination Port <-> pcb->local_port
packet Destination IP   <-> pcb->local_ip / input netif / broadcast 规则
```

继续阅读 `udp_input()`：如果 PCB 没有 `UDP_FLAGS_CONNECTED`，它属于 unconnected PCB。当前实现先记录第一个 local endpoint 匹配的候选。[S2](#source-s2)

```c
if ((pcb->flags & UDP_FLAGS_CONNECTED) == 0) {
  if (uncon_pcb == NULL) {
    /* the first unconnected matching PCB */
    uncon_pcb = pcb;
```

这正对应 Raw Echo 的常见使用方式：`udp_bind()` 只绑定 local port 7，并没有事先绑定唯一的 remote peer，因此任意远端只要发到正确 local endpoint，都可能进入这个 PCB。

### 6.3 Connected PCB 还会继续比较 packet 的远端 endpoint

local endpoint 匹配以后，`udp_input()` 继续检查 packet source 与 PCB remote endpoint：[S2](#source-s2)

```c
/* compare PCB remote addr+port to UDP source addr+port */
if ((pcb->remote_port == src) &&
    (ip_addr_isany_val(pcb->remote_ip) ||
     ip_addr_eq(&pcb->remote_ip, ip_current_src_addr()))) {
```

对应关系是：

```text
pcb->local_port  <-> packet Destination Port
pcb->local_ip    <-> packet Destination IP
pcb->remote_port <-> packet Source Port
pcb->remote_ip   <-> packet Source IP
```

四个方向都满足时，源码称为 `Perfect match`。这种 fully matched connected PCB 优先级高于只匹配 local endpoint 的 unconnected PCB。

继续阅读 `udp_input()`：如果整条链表没有找到 fully matched PCB，遍历结束后才回退到之前记录的 `uncon_pcb`。[S2](#source-s2)

```c
/* no fully matching pcb found? then look for an unconnected pcb */
if (pcb == NULL) {
  pcb = uncon_pcb;
}
```

因此“port 匹配”更准确的心智模型是：

```mermaid
flowchart TD
    A["收到 UDP datagram"] --> B["src = packet Source Port<br/>dest = packet Destination Port"]
    B --> C["for 遍历 udp_pcbs"]
    C --> D{"pcb local port == dest<br/>local IP/netif 匹配?"}
    D -->|"否"| C
    D -->|"是，unconnected"| E["记录 uncon_pcb 候选"]
    D -->|"是"| F{"remote port == src<br/>remote IP 匹配?"}
    F -->|"否"| C
    F -->|"是"| G["Perfect match"]
    C -->|"遍历结束"| H{"有 uncon_pcb?"}
    H -->|"是"| I["使用 unconnected candidate"]
    G --> J["选定 pcb"]
    I --> J
```

### 6.4 为什么完全匹配后还会把 PCB 移到链表头

继续阅读 `udp_input()`：找到 fully matched PCB 后，当前实现还有一个很小但很实用的优化。[S2](#source-s2)

```c
/* the first fully matching PCB */
if (prev != NULL) {
  /* move the pcb to the front of udp_pcbs so that is
     found faster next time */
  prev->next = pcb->next;
  pcb->next = udp_pcbs;
  udp_pcbs = pcb;
} else {
  UDP_STATS_INC(udp.cachehit);
}
break;
```

也就是 **move-to-front**：一个 connected flow 连续收很多 datagram 时，第一次命中的 PCB 会被移到 `udp_pcbs` 表头；下一个同 flow datagram 从头开始遍历时更可能第一项就命中。

这没有改变“线性链表匹配”的本质，只是让热点 PCB 更靠前。

### 6.5 选出 PCB 后，才验证 checksum、移除 UDP Header 并调用 callback

匹配出 `pcb` 之后，`udp_input()` 继续做 UDP checksum 检查。通过后才执行：[S2](#source-s2)

```c
if (pbuf_remove_header(p, UDP_HLEN)) {
  LWIP_ASSERT("pbuf_remove_header failed", 0);
  UDP_STATS_INC(udp.drop);
  MIB2_STATS_INC(mib2.udpinerrors);
  pbuf_free(p);
  goto end;
}
```

于是 `p->payload` 从：

```text
UDP Header
```

推进成：

```text
UDP Payload
```

继续阅读 `udp_input()` 的 callback dispatch 尾部：[S2](#source-s2)

```c
/* callback */
if (pcb->recv != NULL) {
  /* now the recv function is responsible for freeing p */
  pcb->recv(pcb->recv_arg, pcb, p, ip_current_src_addr(), src);
} else {
  /* no recv function registered? then we have to free the pbuf! */
  pbuf_free(p);
  goto end;
}
```

回到第 1 节的 `udpecho_raw_init()`：初始化阶段已经执行过 callback 注册：

```c
udp_recv(pcb, udpecho_raw_recv, NULL);
```

与运行阶段的真实链路终于完整对应：

```text
udp_recv()
  -> 把 udpecho_raw_recv 保存进 pcb->recv

packet 到达
  -> tcpip_thread
  -> udp_input()
  -> 遍历 udp_pcbs
  -> local/remote endpoint 匹配
  -> pbuf_remove_header(UDP_HLEN)
  -> pcb->recv(...)
  -> udpecho_raw_recv(...)
```

这一步才是 UDP demultiplex 的完整含义：同一条 IP input path 根据 packet endpoint 找到一个 PCB，再由 PCB 中预先注册的 function pointer 把 payload 分发给正确的上层 callback。

## 7. callback 看到的 pbuf 已经不是 UDP Header

`udp_input()` 在 callback 前执行 `pbuf_remove_header(p, UDP_HLEN)`。[S2](#source-s2)

所以 callback 收到：

```text
p->payload -> UDP payload
```

而不是：

```text
p->payload -> UDP Header
```

这和 Stage 4 完全相同：每一层处理完自己的 header 后，把 pbuf 数据视图推进到下一层。

callback 参数中的 `addr` 和 `port` 则保存发送方 endpoint：

```text
addr = remote IP
port = remote UDP source port
```

Raw Echo 用它们作为回包目标。

## 8. `udpecho_raw_recv()` 的 ownership 为什么必须看清

upstream callback：[S1](#source-s1)

```c
if (p != NULL) {
  udp_sendto(upcb, p, addr, port);
  pbuf_free(p);
}
```

这里能直接推出一个重要 ownership 契约：**callback 收到这个 RX pbuf 后，示例负责最终释放它。**

`udp_sendto()` 并没有把这个 payload pbuf 永久接管走，所以 callback 在发送调用返回后仍然执行 `pbuf_free(p)`。[S1](#source-s1)[S2](#source-s2)

不要把：

```text
udp_sendto(pcb, p, ...)
```

理解成“p 的 ownership 自动交给 UDP”。如果调用方后续不再需要 p，仍应按 API 语义释放自己的引用。

## 9. Echo TX：UDP Header 在哪里加回来

协议总流程已经完成 RX 分发并进入 Echo callback；现在从接收方向切换到回包方向。callback 把原发送端地址和 Source Port 作为目标交给 `udp_sendto()`，下面继续追 UDP Header 如何重新构造。

`udp_sendto()` 进入 UDP Core 后，会选择 source address/interface、准备 checksum，然后为 UDP Header 腾出空间并填写 source port、destination port、length/checksum，最后进入 IP output。[S2](#source-s2)

因此 callback 传入时：

```text
p->payload -> UDP payload
```

UDP Core 发出时会变成：

```text
UDP Header
+ payload
```

再往下：

```text
udp_sendto()
  -> ip4_output_if_src()
  -> netif->output
  -> etharp_output()
  -> ethernet_output()
  -> low_level_output()
```

ARP cache 如果已经有 Host MAC，就不需要再次广播 ARP；如果没有，`etharp_output()` 会重新触发地址解析。

## 10. 一次 Raw UDP Echo 的完整数据与 ownership 流

```mermaid
flowchart TD
    A["Host UDP datagram<br/>dst port 7"] --> B["ip4_input(): Protocol 17"]
    B --> C["udp_input()"]
    C --> D["匹配 udp_pcbs"]
    D --> E["remove UDP Header"]
    E --> F["udpecho_raw_recv(p, addr, port)"]
    F --> G["udp_sendto(upcb, p, addr, port)"]
    G --> H["重新添加 UDP/IP/Ethernet headers"]
    H --> I["Echo datagram 返回 Host"]
    G --> J["callback 仍持有 RX pbuf 引用"]
    J --> K["pbuf_free(p)"]
```

这张图同时回答两个不同问题：

- 数据怎样返回；
- RX pbuf 最后是谁释放。

两者不能混成“发送成功所以自动 free”。

## 11. Raw API 的线程边界

当前 `example_app` 配置 `NO_SYS=0`，Ethernet RX 通过 `tcpip_input()` 进入 `tcpip_thread`，`udp_input()` 和 Raw recv callback 都在 lwIP Core 上下文里执行。[S3](#source-s3)[S5](#source-s5)

这正是 Raw API 的关键约束：Raw callback 不是普通 application worker thread。回调里直接调用 Core API 很自然，但不能把它当成可以长时间阻塞的业务线程。

Stage 6 会从同一个 UDP Echo 问题出发，改用 Netconn：application thread 阻塞等待 mailbox，而 Core callback 只负责把数据交到 mailbox。

## 资料来源

<a id="source-s1"></a>
### [S1] upstream Raw UDP Echo 示例
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/apps/udpecho_raw/udpecho_raw.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/apps/udpecho_raw/udpecho_raw.c)
- 使用位置：初始化、callback、Echo TX 与 pbuf 释放
- 支撑内容：`udp_new_ip_type()`、`udp_bind()`、`udp_recv()`、`udp_sendto()` 和 `pbuf_free()` 的示例调用顺序

<a id="source-s2"></a>
### [S2] UDP Core 实现
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/udp.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/udp.c)、[`src/include/lwip/udp.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/udp.h)
- 使用位置：PCB allocation/bind/callback、RX demultiplex、TX
- 支撑内容：`udp_input()` 的 PCB 匹配、header removal 和 callback 调用，以及 `udp_sendto()` 的发送语义

<a id="source-s3"></a>
### [S3] IPv4 与 `tcpip_thread` 输入链
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/ipv4/ip4.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/ipv4/ip4.c)、[`src/api/tcpip.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/api/tcpip.c)
- 使用位置：Protocol 17 分发和 callback 执行上下文
- 支撑内容：IPv4 如何进入 `udp_input()`，以及当前 OS 模式下 packet 如何进入 Core thread

<a id="source-s4"></a>
### [S4] RFC 768 — UDP
- URL/文档：[RFC 768 — User Datagram Protocol](https://www.rfc-editor.org/rfc/rfc768.html)
- 使用位置：UDP Header、port、length、checksum
- 支撑内容：UDP datagram 的基本报文格式与 endpoint 字段

<a id="source-s5"></a>
### [S5] example `lwipopts.h`
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/examples/example_app/lwipopts.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/example_app/lwipopts.h)
- 使用位置：当前 `NO_SYS`、UDP 和 Core threading 配置
- 支撑内容：限定本文描述的是当前 Unix `example_app` 构建，而不是所有 lwIP Port 的唯一线程模型

<a id="source-s6"></a>
### [S6] Cloudflare UDP 入门资料
- 类型：公开技术学习资料
- URL/文档：[Cloudflare — 什么是 UDP？](https://www.cloudflare.com/zh-cn/learning/ddos/glossary/user-datagram-protocol-udp/)
- 使用位置：“阅读源码前”、UDP 协议模型
- 支撑内容：提供面向初学者的 UDP 无连接 datagram 与可靠性边界补充说明；正文仍独立建立当前源码所需的协议模型

<a id="source-s7"></a>
### [S7] IANA Service Name and Transport Protocol Port Number Registry
- 类型：IANA 官方注册表
- 版本：访问时注册表（2026-09-30 更新）
- URL/文档：[IANA — echo service / port 7](https://www.iana.org/assignments/service-names-port-numbers?search=echo)
- 使用位置：`udp_bind(..., 7)`
- 支撑内容：确认 `echo` 同时注册于 TCP/UDP port 7；本文据此解释 upstream Raw UDP Echo 示例为何绑定本地 UDP port 7



<a id="source-s8"></a>
### [S8] lwIP 官方 UDP Raw API 文档
- 类型：lwIP 官方 Doxygen 文档
- 版本：2.1.x 文档；正文源码事实以固定 commit `d08f4773edd0182b7910fc8f046eed82ffcd67c9` 为准
- URL/文档：[lwIP — UDP Raw API](https://www.nongnu.org/lwip/2_1_x/group__udp__raw.html)
- 使用位置：“阅读源码前”、公开 API 导航
- 支撑内容：说明 `udp_new()`、`udp_bind()`、`udp_recv()`、`udp_sendto()` 属于 lwIP UDP Raw API；具体执行链由 [S1]～[S3] 的目标源码证明
