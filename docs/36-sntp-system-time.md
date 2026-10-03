<meta name="referrer" content="no-referrer" />

# 教程 36：从 `sntp_example_init()` 到 `sntp_process()`——SNTP、DHCP/DNS、Timer 与系统时间同步

> 摘要：从 upstream SNTP example 追踪 Server 来源、DNS/UDP 请求、响应校验、Timer 与系统时间更新，并说明可靠时间为何会影响 TLS 证书验证和云连接。

[TOC]

SNTP（Simple Network Time Protocol，简单网络时间协议）是 NTP（Network Time Protocol，网络时间协议）的简化客户端使用方式。设备通常作为 Client，经 UDP 向时间 Server 发送请求，从响应里的 NTP timestamp 得到 wall clock 时间，再通过平台 hook 更新系统时钟。MCU/IoT 产品常在 TLS/Cloud 建连前先完成这一步，因为证书有效期判断、日志时间和业务时间戳都依赖一个足够可信的系统时间。[S6](#source-s6)[S9](#source-s9)

Stage 13 已经追过 **DHCP（Dynamic Host Configuration Protocol）**，它负责自动获得网络参数，并可通过 Option 42 提供 NTP Server 地址；Stage 14 已经追过 **DNS（Domain Name System，域名系统）**，它负责把 Server hostname 解析成 IP address。这里的 **Timer** 是 lwIP `sys_timeout()` 定时机制，用于安排首次 request、receive timeout、retry 和下一轮 poll。Stage 36 采用 Source-driven 主线，从 upstream 的 `sntp_example_init()` 出发，把这些已有模块接到 SNTP 时间同步上。[S1](#source-s1)[S2](#source-s2)[S3](#source-s3)[S4](#source-s4)

## 0. 进入源码前先建立 SNTP/NTP 最小协议模型

### 0.1 建议提前阅读：规范用于校对，正文仍可独立阅读

1. [Cisco — Simple Network Time Protocol](https://www.cisco.com/c/en/us/td/docs/routers/ios-xe/system-management/system-management/m_bsm-sntpv4.html)
   - 用途：快速建立“SNTP 是轻量 client-side time synchronization”的工程模型。[S9](#source-s9)
2. [RFC 5905 — Network Time Protocol Version 4](https://www.rfc-editor.org/rfc/rfc5905.html)
   - 用途：确认 NTPv4 线上报文、时间表示、Client/Server 角色以及 Server 拒绝/限速响应等规范语义。[S6](#source-s6)
3. [RFC 4330 — Simple Network Time Protocol Version 4](https://www.rfc-editor.org/rfc/rfc4330.html)
   - 用途：解释为什么当前 lwIP `sntp.c` 的历史注释仍引用这个已被 RFC 5905 取代的文档。[S5](#source-s5)

当前协议语义以 RFC 5905 为主要规范锚点；RFC 4330 只承担目标源码历史背景。

### 0.2 一次 SNTP poll 到底发生什么

本文只讨论 upstream example 选择的 **poll mode（轮询模式）**：Client 主动向 Server 的 **UDP port 123** 发送 NTP-format request，Server 返回 response。NTP 的基本报文有 48-byte base header；lwIP 当前 `SNTP_MSG_LEN` 也固定为 48 bytes。[S2](#source-s2)[S6](#source-s6)

第一字节把三个概念编码在一起：

- **LI（Leap Indicator）**：与闰秒/时钟告警相关的 2-bit 字段；
- **VN（Version Number）**：NTP version；
- **Mode**：当前报文角色。本文主线中 Client request 使用 Client mode，正常 Server response 使用 Server mode。[S6](#source-s6)

**Stratum（层级）**描述 Server 距离参考时钟的层次。当前 lwIP 把 `stratum == 0` 作为 Kiss-o'-Death（KoD）处理：该响应表示当前 Server 不应像正常时间源一样被使用，multiple-server 构建会标记该 Server 并尝试其他 Server，单 Server 构建则进入 retry policy。[S2](#source-s2)[S6](#source-s6)

### 0.3 NTP Timestamp：不是 Unix `time_t`

NTP timestamp 是 64-bit fixed-point 时间表示，由 **32-bit seconds + 32-bit fractional seconds** 组成，epoch 与 Unix epoch 不同。[S6](#source-s6) 一次 request/response 中常讨论四个时刻：

- **Originate Timestamp（T1）**：Client 发送 request 的时刻，在 response 中用于把回包关联回原 request；
- **Receive Timestamp（T2）**：Server 收到 request 的时刻；
- **Transmit Timestamp（T3）**：Server 发出 response 的时刻；
- **Destination Timestamp（T4）**：Client 收到 response 的本地时刻。

当前 lwIP 的最小同步路径最终主要从 response timestamp 计算系统时间；当 `SNTP_CHECK_RESPONSE >= 2` 时还会比较 response 的 Originate Timestamp 与上一次 request 中保存的 transmit timestamp，`SNTP_COMP_ROUNDTRIP` 则使用更多时间戳信息做 round-trip compensation。[S2](#source-s2)[S3](#source-s3) 后文到 `sntp_initialize_request()` 与 `sntp_process()` 时再看这些 wire fields 如何映射到 C 数据。

### 0.4 协议总流程：从 Server 来源到系统时间更新

```mermaid
sequenceDiagram
    participant App as "SNTP application"
    participant Core as "lwIP SNTP client"
    participant DNS as "DNS resolver"
    participant S as "Time Server UDP/123"

    App->>Core: sntp_example_init()
    Note over Core: 选择 Server 来源<br/>DHCP address, configured IP, or hostname
    opt hostname configured
        Core->>DNS: resolve server name
        DNS-->>Core: server IP address
    end
    Core->>S: NTP-format request<br/>Client Mode
    S-->>Core: NTP-format response<br/>Server Mode, Stratum, timestamps
    Note over Core: 校验 source, length, Mode<br/>optional Originate Timestamp check
    Core->>Core: sntp_process()<br/>convert timestamp and update system time
    Note over Core: schedule next poll or retry
```

图里出现的 **DHCP address** 指 DHCP Option 42 下发的 NTP Server address；这只有在相应 compile-time option 与 runtime `sntp_servermode_dhcp()` 都满足时才会真正进入 `sntp_servers[]`，后文会从源码证明这一点。[S3](#source-s3)[S4](#source-s4)

### 0.5 协议动作怎样映射到 lwIP 源码

| SNTP 阶段 | 协议/控制动作 | lwIP 主要入口 | 关键对象/字段 | 下一步 |
| --- | --- | --- | --- | --- |
| 选择 Server | DHCP/configured IP/hostname | `sntp_example_init()`、`dhcp_set_ntp_servers()`、`sntp_setserver()` | `sntp_servers[]` | `sntp_init()` |
| 创建 Client | 建立 UDP endpoint | `sntp_init()` | SNTP UDP PCB | 安排第一次 request |
| 获取地址 | hostname → IP | `sntp_request()` → `dns_gethostbyname()` | current server entry | `sntp_dns_found()` |
| 发送 request | Client Mode request → UDP/123 | `sntp_send_request()` → `sntp_initialize_request()` | 48-byte `sntp_msg` | 等 response / timeout |
| 校验 response | Server Mode、source、length、Stratum、optional Originate check | `sntp_recv()` | `sntp_timestamps` | 正常处理、KoD 或 retry |
| 更新时间 | NTP timestamp → platform clock | `sntp_process()` → `SNTP_SET_SYSTEM_TIME*` | seconds/fraction | 安排下一次 poll |

从下一节开始，正文沿这张表的实际调用顺序进入源码。

## 1. 从 `sntp_example_init()` 开始：example 先决定 Server 从哪里来

upstream example 的入口很短，但已经把 SNTP 初始化顺序写得很清楚：[S1](#source-s1)

```c
void
sntp_example_init(void)
{
  sntp_setoperatingmode(SNTP_OPMODE_POLL);
#if LWIP_DHCP
  sntp_servermode_dhcp(1); /* get SNTP server via DHCP */
#else /* LWIP_DHCP */
#if LWIP_IPV4
  sntp_setserver(0, netif_ip_gw4(netif_default));
#endif /* LWIP_IPV4 */
#endif /* LWIP_DHCP */
  sntp_init();
}
```

当前 example 选择 `SNTP_OPMODE_POLL`，也就是设备作为 SNTP client 主动向 Server 发 request，而不是监听广播时间。然后它根据构建配置选择 Server 来源：

```mermaid
flowchart TD
    A["sntp_example_init()"] --> B["SNTP_OPMODE_POLL"]
    B --> C{"LWIP_DHCP ?"}
    C -->|"yes"| D["sntp_servermode_dhcp(1)"]
    C -->|"no"| E["sntp_setserver(0, default gateway)"]
    D --> F["sntp_init()"]
    E --> F
```

这里有一个必须在 example 第一次出现时就说明的实现边界：**`LWIP_DHCP` 打开，不等于 DHCP 一定会把 NTP Server 交给 SNTP。** `sntp_servermode_dhcp()` 只有在 `SNTP_GET_SERVERS_FROM_DHCP` 或 DHCPv6 对应选项启用时才是真函数；否则 public header 直接把它定义为空宏。[S3](#source-s3)

而当前默认配置又是：[S3](#source-s3)[S4](#source-s4)

```text
LWIP_DHCP_GET_NTP_SRV = 0
SNTP_GET_SERVERS_FROM_DHCP = LWIP_DHCP_GET_NTP_SRV
```

所以如果只是打开 `LWIP_DHCP=1`，却没有额外打开 `LWIP_DHCP_GET_NTP_SRV`，继续阅读 `sntp_example_init()` 中的这条调用：

```c
sntp_servermode_dhcp(1);
```

不会自动产生一个可用 NTP Server。这不是 SNTP 协议限制，而是当前 lwIP 的编译配置关系。

## 2. DHCP Server 地址怎样真正进入 SNTP

当 `LWIP_DHCP_GET_NTP_SRV` 被启用后，Stage 13 里已经存在的 DHCP option parser 会开始接受 DHCP Option 42（NTP Server）。`dhcp.h` 同时要求系统提供：

```c
extern void dhcp_set_ntp_servers(u8_t num_ntp_servers, const ip4_addr_t* ntp_server_addrs);
```

SNTP module 正好实现了这个 callback。[S2](#source-s2)[S4](#source-s4)

调用关系是：

```mermaid
flowchart LR
    A["DHCP ACK / Option 42"] --> B["dhcp option parser"]
    B --> C["dhcp_set_ntp_servers()"]
    C --> D["sntp_setserver(i, addr)"]
    D --> E["sntp_servers[]"]
```

`dhcp_set_ntp_servers()` 还会检查 `sntp_set_servers_from_dhcp`。这个 flag 正是前面 `sntp_servermode_dhcp(1)` 设置的。因此 DHCP-NTP 集成要同时满足两个条件：

1. 编译时启用 `LWIP_DHCP_GET_NTP_SRV`；
2. 运行时允许 SNTP 接受 DHCP 下发的 Server。

这就是为什么不能把 `sntp_servermode_dhcp(1)` 理解成“主动去 DHCP 查询一次 NTP Server”。它只是打开 **DHCP callback 写入 SNTP server table 的许可**。

## 3. 进入 `sntp_init()`：真正创建的是一个 UDP Raw PCB

` sntp_example_init()` 最后调用 `sntp_init()`。下面进入 `sntp_init()`。[S2](#source-s2)

```c
void
sntp_init(void)
{
  /* LWIP_ASSERT_CORE_LOCKED(); is checked by udp_new() */
  LWIP_DEBUGF(SNTP_DEBUG_TRACE, ("sntp_init: SNTP initialised\n"));

#ifdef SNTP_SERVER_ADDRESS
#if SNTP_SERVER_DNS
  sntp_setservername(0, SNTP_SERVER_ADDRESS);
#else
#error SNTP_SERVER_ADDRESS string not supported SNTP_SERVER_DNS==0
#endif
#endif /* SNTP_SERVER_ADDRESS */

  if (sntp_pcb == NULL) {
    sntp_pcb = udp_new_ip_type(IPADDR_TYPE_ANY);
    LWIP_ASSERT("Failed to allocate udp pcb for sntp client", sntp_pcb != NULL);
    if (sntp_pcb != NULL) {
      udp_recv(sntp_pcb, sntp_recv, NULL);

      if (sntp_opmode == SNTP_OPMODE_POLL) {
        SNTP_RESET_RETRY_TIMEOUT();
#if SNTP_STARTUP_DELAY
        sys_timeout((u32_t)SNTP_STARTUP_DELAY_FUNC, sntp_request, NULL);
#else
        sntp_request(NULL);
#endif
      } else if (sntp_opmode == SNTP_OPMODE_LISTENONLY) {
        ip_set_option(sntp_pcb, SOF_BROADCAST);
        udp_bind(sntp_pcb, IP_ANY_TYPE, SNTP_PORT);
      }
    }
  }
}
```

这段代码完成三个关键动作：

- `udp_new_ip_type()` 创建 SNTP 专用 UDP PCB；
- `udp_recv(..., sntp_recv, ...)` 把回包入口绑定到 `sntp_recv()`；
- Poll mode 下安排第一次 `sntp_request()`。

因此 SNTP 并没有自己的线程。它仍然使用 lwIP Raw UDP API + `sys_timeout()` 驱动状态推进：

```text
UDP PCB
  + recv callback
  + sys_timeout()
  = SNTP client runtime
```

这也延续 Stage 11 的线程规则：在 `NO_SYS=0` 下，SNTP 属于 callback-style lwIP core API。`sntp_init()` 本身明确依赖 `udp_new()` 的 core-lock assertion，普通 RTOS task 或 IRQ 不能在没有 TCPIP-thread 调度/core locking 的情况下随意直接调用这些接口。[S8](#source-s8)

## 4. 第一次请求不是一定立即发送：`SNTP_STARTUP_DELAY` 决定入口时机

Poll mode 下存在两条进入 `sntp_request()` 的路径：

```text
SNTP_STARTUP_DELAY = 0
    -> sntp_init()
    -> sntp_request() immediately

SNTP_STARTUP_DELAY = 1
    -> sys_timeout(..., sntp_request, NULL)
    -> timeout expires
    -> sntp_request()
```

当前 `sntp_opts.h` 在存在 `LWIP_RAND` 时默认打开 startup delay，并把默认函数定义为 `LWIP_RAND() % 5000`。[S3](#source-s3) 源码注释同时引用 RFC 对启动随机延迟的要求；这里应区分“规范意图”和“当前默认实现值”，不要把当前宏值泛化成 SNTP 协议常量。

进入 `sntp_request()` 后，才真正决定此次请求使用 **IP 地址还是 DNS 名称**。

## 5. 进入 `sntp_request()`：DNS 只是 Server 地址获取的一条分支

`sntp_request()` 本身已经完整体现了“域名路径 / 已知 IP 路径 / 地址失败重试”三种结果。[S2](#source-s2)

```c
static void
sntp_request(void *arg)
{
  ip_addr_t sntp_server_address;
  err_t err;

  LWIP_UNUSED_ARG(arg);

  /* initialize SNTP server address */
#if SNTP_SERVER_DNS
  if (sntp_servers[sntp_current_server].name) {
    /* always resolve the name and rely on dns-internal caching & timeout */
    ip_addr_set_zero(&sntp_servers[sntp_current_server].addr);
    err = dns_gethostbyname(sntp_servers[sntp_current_server].name, &sntp_server_address,
                            sntp_dns_found, NULL);
    if (err == ERR_INPROGRESS) {
      /* DNS request sent, wait for sntp_dns_found being called */
      LWIP_DEBUGF(SNTP_DEBUG_STATE, ("sntp_request: Waiting for server address to be resolved.\n"));
      return;
    } else if (err == ERR_OK) {
      sntp_servers[sntp_current_server].addr = sntp_server_address;
    }
  } else
#endif /* SNTP_SERVER_DNS */
  {
    sntp_server_address = sntp_servers[sntp_current_server].addr;
    err = (ip_addr_isany_val(sntp_server_address)) ? ERR_ARG : ERR_OK;
  }

  if (err == ERR_OK) {
    LWIP_DEBUGF(SNTP_DEBUG_TRACE, ("sntp_request: current server address is %s\n",
                                   ipaddr_ntoa(&sntp_server_address)));
    sntp_send_request(&sntp_server_address);
  } else {
    /* address conversion failed, try another server */
    LWIP_DEBUGF(SNTP_DEBUG_WARN_STATE, ("sntp_request: Invalid server address, trying next server.\n"));
    sys_untimeout(sntp_try_next_server, NULL);
    sys_timeout((u32_t)SNTP_RETRY_TIMEOUT, sntp_try_next_server, NULL);
  }
}
```

当 `dns_gethostbyname()` 返回 `ERR_INPROGRESS` 时，本次 `sntp_request()` 到这里结束；后续不是同步返回到该函数，而是 DNS resolver 完成后触发之前传入的 `sntp_dns_found()`。在 `SNTP_SERVER_DNS=1` 的构建中，继续进入这个 callback：[S2](#source-s2)

```c
static void
sntp_dns_found(const char *hostname, const ip_addr_t *ipaddr, void *arg)
{
  LWIP_UNUSED_ARG(hostname);
  LWIP_UNUSED_ARG(arg);

  if (ipaddr != NULL) {
    /* Address resolved, send request */
    LWIP_DEBUGF(SNTP_DEBUG_STATE, ("sntp_dns_found: Server address resolved, sending request\n"));
    sntp_servers[sntp_current_server].addr = *ipaddr;
    sntp_send_request(ipaddr);
  } else {
    /* DNS resolving failed -> try another server */
    LWIP_DEBUGF(SNTP_DEBUG_WARN_STATE, ("sntp_dns_found: Failed to resolve server address resolved, trying next server\n"));
    sntp_try_next_server(NULL);
  }
}
```

解析成功时 callback 把地址写回当前 `sntp_servers[]` 项并立即进入 `sntp_send_request()`；解析失败则进入 `sntp_try_next_server()`。因此异步桥接完整链路是：

这里和 Stage 14 的异步 DNS 模型完全一致：

```mermaid
flowchart TD
    A["sntp_request()"] --> B{"server has DNS name?"}
    B -->|"no"| C["use configured IP address"]
    B -->|"yes"| D["dns_gethostbyname()"]
    D -->|"ERR_OK / cached"| E["sntp_send_request()"]
    D -->|"ERR_INPROGRESS"| F["wait for sntp_dns_found()"]
    F -->|"resolved"| E
    F -->|"failed"| G["sntp_try_next_server()"]
    C --> E
```

这说明 DNS 不是 SNTP 的一部分。SNTP core 只是允许 Server table 保存 hostname，并复用 lwIP DNS resolver 把 hostname 转成 `ip_addr_t`。

当前 upstream 默认 `SNTP_SERVER_DNS=0`，因此要使用类似 `pool.ntp.org` 的名字，必须在 `lwipopts.h` 中显式开启该能力。[S3](#source-s3)

## 6. 进入 `sntp_send_request()`：48 字节 request 通过 UDP/123 发出

地址已经确定后，`sntp_request()` 调用 `sntp_send_request()`。下面进入该函数。[S2](#source-s2)

```c
static void
sntp_send_request(const ip_addr_t *server_addr)
{
  struct pbuf *p;

  LWIP_ASSERT("server_addr != NULL", server_addr != NULL);

  p = pbuf_alloc(PBUF_TRANSPORT, SNTP_MSG_LEN, PBUF_RAM);
  if (p != NULL) {
    struct sntp_msg *sntpmsg = (struct sntp_msg *)p->payload;
    LWIP_DEBUGF(SNTP_DEBUG_STATE, ("sntp_send_request: Sending request to server\n"));
    /* initialize request message */
    sntp_initialize_request(sntpmsg);
    /* send request */
    udp_sendto(sntp_pcb, p, server_addr, SNTP_PORT);
    /* free the pbuf after sending it */
    pbuf_free(p);
#if SNTP_MONITOR_SERVER_REACHABILITY
    /* indicate new packet has been sent */
    sntp_servers[sntp_current_server].reachability <<= 1;
#endif /* SNTP_MONITOR_SERVER_REACHABILITY */
    /* set up receive timeout: try next server or retry on timeout */
    sys_untimeout(sntp_try_next_server, NULL);
    sys_timeout((u32_t)SNTP_RECV_TIMEOUT, sntp_try_next_server, NULL);
#if SNTP_CHECK_RESPONSE >= 1
    /* save server address to verify it in sntp_recv */
    ip_addr_copy(sntp_last_server_address, *server_addr);
#endif /* SNTP_CHECK_RESPONSE >= 1 */
  } else {
    LWIP_DEBUGF(SNTP_DEBUG_SERIOUS, ("sntp_send_request: Out of memory, trying again in %"U32_F" ms\n",
                                     (u32_t)SNTP_RETRY_TIMEOUT));
    /* out of memory: set up a timer to send a retry */
    sys_untimeout(sntp_request, NULL);
    sys_timeout((u32_t)SNTP_RETRY_TIMEOUT, sntp_request, NULL);
  }
}
```

RFC 5905 已经定义 NTPv4 的 base packet 与 UDP transport；这里不重新展开报文字段，只看当前 lwIP 如何落实它：`SNTP_MSG_LEN` 固定为 48 字节，`SNTP_PORT` 映射到标准 UDP/123。[S2](#source-s2)[S3](#source-s3)[S6](#source-s6)

`pbuf_free(p)` 紧跟在 `udp_sendto()` 后并不代表数据已经从 PHY 发完；这里遵循 Raw UDP API 对发送数据复制/引用的既有 contract。Stage 03/05 已经讲过 pbuf 与 UDP send path，本篇只关注 SNTP 自己增加的状态。

发送成功后还会安排：

```text
SNTP_RECV_TIMEOUT
    ↓
sntp_try_next_server()
```

所以一次 poll request 从发送那一刻就带着“如果没收到有效响应怎么办”的 Timer。

## 7. `sntp_initialize_request()`：把标准 Mode/Timestamp 映射到 lwIP 字段

`sntp_send_request()` 先调用 `sntp_initialize_request()` 构造 48 字节报文。[S2](#source-s2) 下面直接进入该函数：

```c
static void
sntp_initialize_request(struct sntp_msg *req)
{
  memset(req, 0, SNTP_MSG_LEN);
  req->li_vn_mode = SNTP_LI_NO_WARNING | SNTP_VERSION | SNTP_MODE_CLIENT;

#if SNTP_CHECK_RESPONSE >= 2 || SNTP_COMP_ROUNDTRIP
  {
    s32_t secs;
    u32_t sec, frac;
    /* Get the transmit timestamp */
    SNTP_GET_SYSTEM_TIME_NTP(secs, frac);
    sec  = lwip_htonl((u32_t)secs);
    frac = lwip_htonl(frac);

# if SNTP_CHECK_RESPONSE >= 2
    sntp_last_timestamp_sent.sec  = sec;
    sntp_last_timestamp_sent.frac = frac;
# endif
    req->transmit_timestamp[0] = sec;
    req->transmit_timestamp[1] = frac;
  }
#endif /* SNTP_CHECK_RESPONSE >= 2 || SNTP_COMP_ROUNDTRIP */
}
```

RFC 5905 已经定义 `LI | VN | Mode` 与 64-bit NTP timestamp 的线格式；源码篇只需要把这些标准对象对回当前实现。[S6](#source-s6)

| 标准对象 | 当前 lwIP 落点 | 本文继续关注的实现含义 |
| --- | --- | --- |
| client mode | `SNTP_MODE_CLIENT` | request 以 client mode 发出 |
| protocol version | `SNTP_VERSION` | 与 `LI` 一起写入 `li_vn_mode` |
| transmit timestamp | `req->transmit_timestamp[0/1]` | 只有开启强化 response check 或 round-trip compensation 时才写入本地发送时刻 |
| originate timestamp check | `sntp_last_timestamp_sent` | response 路径可用它校验请求/响应对应关系 |

前面的协议基线已经说明 NTP timestamp 与 Unix `time_t` 不是同一种时间表示；这里继续关注 lwIP 自己的数据表示策略：`sntp.c` 使用 signed 32-bit seconds 相对 2036 epoch，再通过 `DIFF_SEC_1970_2036` 与 Unix epoch 互转，使当前实现覆盖约 1968～2104 的日期范围。[S2](#source-s2) 应用通常无需直接处理这些 wire fields，只需要正确实现系统时间读写宏。

## 8. 回包入口早在 `sntp_init()` 已经绑定：UDP 最终调用 `sntp_recv()`

前面 `sntp_init()` 已执行：

```c
udp_recv(sntp_pcb, sntp_recv, NULL);
```

因此 UDP/123 response 匹配到这个 PCB 后，会通过 Raw UDP callback 到达 `sntp_recv()`。这里不存在额外 SNTP worker thread。

`sntp_recv()` 的检查顺序是：[S2](#source-s2)

```mermaid
flowchart TD
    A["sntp_recv()"] --> B{"source addr/port valid?"}
    B -->|"no"| Z["ignore / wait or retry"]
    B -->|"yes"| C{"pbuf total length == 48?"}
    C -->|"no"| Z
    C -->|"yes"| D{"Mode == SERVER?"}
    D -->|"no"| Z
    D -->|"yes"| E{"Stratum == 0?"}
    E -->|"yes"| F["Kiss-of-Death path"]
    E -->|"no"| G["copy timestamps"]
    G --> H{"optional originate timestamp check"}
    H -->|"pass"| I["sntp_process()"]
```

默认 `SNTP_CHECK_RESPONSE=0`，因此 source address/port 和 Originate Timestamp 的强化校验默认没有全部打开。[S3](#source-s3) 这同样是当前 lwIP 的尺寸/健壮性折中，不是协议允许任意 response 的意思。

## 9. `stratum == 0`：当前 lwIP 怎样处理 Kiss-o'-Death

RFC 5905 的 KoD 语义不仅包含 Stratum 0，还使用 Reference ID 携带 kiss code。[S6](#source-s6) 当前 lwIP 这条 receive path 更简化：`sntp_recv()` 只读取 `stratum`，只要发现 `stratum == 0` 就标记为 `SNTP_ERR_KOD`，并没有在这个分支继续解析 kiss code。[S2](#source-s2) 因此这里应理解成 **目标实现的简化 KoD 判定**，而不是把“任意 Stratum 0 都等价于完整标准 KoD 处理”泛化为协议规则。

当前 `sntp_recv()` 检出 `stratum == 0` 后先把结果标成 `SNTP_ERR_KOD`；函数尾部再调用 `sntp_kod_try_next_server()`，它给当前 server 置 `kod_received` 后进入 `sntp_try_next_server()`。[S2](#source-s2) 多 Server 构建下继续阅读 `sntp_try_next_server()`：

```c
static void
sntp_try_next_server(void *arg)
{
  u8_t old_server, i;
  LWIP_UNUSED_ARG(arg);

  old_server = sntp_current_server;
  for (i = 0; i < SNTP_MAX_SERVERS - 1; i++) {
    sntp_current_server++;
    if (sntp_current_server >= SNTP_MAX_SERVERS) {
      sntp_current_server = 0;
    }
    if (sntp_servers[sntp_current_server].kod_received) {
      /* KOD received, don't use this server */
      continue;
    }
    if (!ip_addr_isany(&sntp_servers[sntp_current_server].addr)
#if SNTP_SERVER_DNS
        || (sntp_servers[sntp_current_server].name != NULL)
#endif
       ) {
      LWIP_DEBUGF(SNTP_DEBUG_STATE, ("sntp_try_next_server: Sending request to server %"U16_F"\n",
                                     (u16_t)sntp_current_server));
      /* new server: reset retry timeout */
      SNTP_RESET_RETRY_TIMEOUT();
      /* instantly send a request to the next server */
      sntp_request(NULL);
      return;
    }
  }
  /* no other valid server found */
  sntp_current_server = old_server;
  sntp_retry(NULL);
}
```

所以多个 Server 时并不是简单“server index + 1”：它跳过已收到 KoD 的条目，也跳过没有地址/名称的空条目；找到可用项后重置 retry timeout 并重新进入 `sntp_request()`。没有其他可用 Server 时恢复旧索引并进入 `sntp_retry()`。

如果只有一个 Server，则退化为 retry/backoff。

因此 `SNTP_MAX_SERVERS` 不只是一个数组大小，它直接决定失败时能否切换时间源。当前默认 `SNTP_MAX_SERVERS` 继承 `LWIP_DHCP_MAX_NTP_SERVERS`。[S3](#source-s3)

## 10. 进入 `sntp_process()`：真正改变系统时间的不是 SNTP core 自己

收到合法 response 后，`sntp_recv()` 调用 `sntp_process()`。下面进入 `sntp_process()`。[S2](#source-s2)

它首先取 Server 的 Transmit Timestamp：

```text
timestamps->xmit
    ↓
seconds + fraction
```

若 `SNTP_COMP_ROUNDTRIP=1`，当前实现会把本地发送/接收时刻与 Server receive/transmit timestamp 一起用于 clock-offset compensation；四时间戳模型的协议算法直接参考 RFC 5905，本文只追它在 `sntp_process()` 中的实现分支。[S2](#source-s2)[S3](#source-s3)[S6](#source-s6) 当前默认该功能关闭。

继续阅读 `sntp_process()` 的末尾，无论是否做 round-trip compensation，最终都会到达：

```c
SNTP_SET_SYSTEM_TIME_NTP(sec, frac);
```

这是最重要的 Port 边界。

lwIP SNTP client 负责的是：

```text
得到“现在应该是什么时间”
```

它并不知道目标平台如何保存时间。真正把时间写进：

```text
Linux system clock
RTC
RTOS wall clock
MCU RTC peripheral
software epoch counter
```

属于平台/应用 Port。

如果项目没有定义更高精度接口，`SNTP_SET_SYSTEM_TIME_NTP()` 最终会降级到 `SNTP_SET_SYSTEM_TIME(sec)`。而 `sntp_opts.h` 给出的默认 `SNTP_SET_SYSTEM_TIME(sec)` 只是 `LWIP_UNUSED_ARG(sec)`，也就是 **默认什么都不设置**。[S2](#source-s2)[S3](#source-s3)

这意味着“SNTP packet 收到了”不等于“产品系统时间已经更新”。产品 Port 必须真正接上系统时钟。

## 11. upstream example 为什么只打印时间，而没有真正 set clock

`contrib/examples/sntp/sntp_example.c` 自己实现了：

```c
void
sntp_set_system_time(u32_t sec)
{
  char buf[32];
  struct tm current_time_val;
  time_t current_time = (time_t)sec;

#if defined(_WIN32) || defined(WIN32)
  localtime_s(&current_time_val, &current_time);
#else
  localtime_r(&current_time, &current_time_val);
#endif

  strftime(buf, sizeof(buf), "%d.%m.%Y %H:%M:%S", &current_time_val);
  LWIP_PLATFORM_DIAG(("SNTP time: %s\n", buf));
}
```

这是 **example behavior**：它把收到的时间转换成人类可读字符串并打印，用于演示 SNTP client 已得到时间。[S1](#source-s1)

生产 MCU 上不能把这一段理解为“SNTP 已经自动驱动 RTC”。真正产品实现应该让 `SNTP_SET_SYSTEM_TIME` / `SNTP_SET_SYSTEM_TIME_US` / `SNTP_SET_SYSTEM_TIME_NTP` 接到目标平台的系统时钟策略。

## 12. 一次同步成功后并不会结束：下一次请求由 Timer 再次启动

继续阅读 `sntp_recv()` 的成功分支，周期调度不是概念层推断，而是函数在处理完时间戳后直接重新注册 `sntp_request()` timeout：[S2](#source-s2)

```c
  if (err == ERR_OK) {
    /* correct packet received: process it it */
    sntp_process(&timestamps);

#if SNTP_MONITOR_SERVER_REACHABILITY
    /* indicate that server responded */
    sntp_servers[sntp_current_server].reachability |= 1;
#endif /* SNTP_MONITOR_SERVER_REACHABILITY */
    /* Set up timeout for next request (only if poll response was received)*/
    if (sntp_opmode == SNTP_OPMODE_POLL) {
      u32_t sntp_update_delay;
      sys_untimeout(sntp_try_next_server, NULL);
      sys_untimeout(sntp_request, NULL);

      /* Correct response, reset retry timeout */
      SNTP_RESET_RETRY_TIMEOUT();

      sntp_update_delay = (u32_t)SNTP_UPDATE_DELAY;
      sys_timeout(sntp_update_delay, sntp_request, NULL);
      LWIP_DEBUGF(SNTP_DEBUG_STATE, ("sntp_recv: Scheduled next time request: %"U32_F" ms\n",
                                     sntp_update_delay));
    }
  } else if (err == SNTP_ERR_KOD) {
    /* KOD errors are only processed in case of an explicit poll response */
    if (sntp_opmode == SNTP_OPMODE_POLL) {
      /* Kiss-of-death packet. Use another server or increase UPDATE_DELAY. */
      sntp_kod_try_next_server(NULL);
    }
  } else {
    /* ignore any broken packet, poll mode: retry after timeout to avoid flooding */
  }
}
```

这段代码依次完成：更新系统时间、标记 reachability、取消当前失败/请求 timeout、重置 retry timeout，并用 `SNTP_UPDATE_DELAY` 安排下一次 `sntp_request()`。

当前默认值包括：[S3](#source-s3)

| 配置 | 当前默认值 | 当前实现中的作用 |
|---|---:|---|
| `SNTP_RECV_TIMEOUT` | 15000 ms | 等待 response，超时后切 Server/重试 |
| `SNTP_UPDATE_DELAY` | 3600000 ms | 成功同步后的下一次 poll，默认 1 小时 |
| `SNTP_RETRY_TIMEOUT` | `SNTP_RECV_TIMEOUT` | 初始 retry delay |
| `SNTP_RETRY_TIMEOUT_EXP` | 1 | retry delay 指数增加 |
| `SNTP_RETRY_TIMEOUT_MAX` | `SNTP_RETRY_TIMEOUT * 10` | retry delay 上限 |
| `SNTP_MONITOR_SERVER_REACHABILITY` | 1 | 每 Server 维护 reachability shift register |

这些是当前 upstream 默认配置，不是所有产品都应该照搬的固定参数。

成功路径因此是一个周期循环：

```mermaid
flowchart LR
    A["sntp_request()"] --> B["UDP request"]
    B --> C["sntp_recv()"]
    C --> D["sntp_process()"]
    D --> E["set system time"]
    E --> F["SNTP_UPDATE_DELAY"]
    F --> A
```

失败路径则由 `SNTP_RECV_TIMEOUT`、`sntp_retry()` 和 `sntp_try_next_server()` 推动。

## 13. 为什么云设备经常在 TLS 之前做时间同步

SNTP 与 TLS 没有直接函数调用关系：

```text
sntp_process()
  X
altcp_tls / mbedTLS
```

真正关系发生在系统时间这一公共资源上。

X.509 certificate 通常携带有效期区间。Mbed TLS 的 X.509 verify API 定义了 `MBEDTLS_X509_BADCERT_EXPIRED` 和 `MBEDTLS_X509_BADCERT_FUTURE`，并提供基于 system time 判断证书时间是否已过期/尚未生效的逻辑。[S7](#source-s7)

因此典型 MCU 云连接启动顺序会是：

```mermaid
flowchart TD
    A["Link Up"] --> B["DHCP"]
    B --> C["DNS available"]
    C --> D["SNTP sync"]
    D --> E["system wall clock valid"]
    E --> F["TLS certificate verification"]
    F --> G["HTTPS / MQTT over TLS"]
```

这里必须保留一个配置边界：**证书是否实际进行有效期检查，取决于具体 Mbed TLS build 与验证配置。** 因此不能写成“没有 SNTP 就绝对无法 TLS handshake”；准确说法是：当产品要求基于可信系统时间完成 X.509 有效期验证时，设备必须在验证前得到合理的当前时间，SNTP 是常见时间来源之一。[S7](#source-s7)

有 RTC、电池保持、可信启动时间或其他安全时间源的系统，不一定每次上电都必须先完成 SNTP。

## 14. SNTP 在产品网络状态机里的位置

前面已经学习过 DHCP、DNS、TLS、MQTT。现在可以给“网络 ready”增加一个更细的定义：

```text
L2/L3 ready
    = link up + IP address available

name service ready
    = DNS available

time ready
    = wall clock valid enough for product policy

secure cloud ready
    = TLS authenticated + application protocol connected
```

因此真实产品不要只维护一个模糊的：

```text
network_connected = true
```

而应该意识到这些状态可能分阶段到达。Stage 45 最终会把它们重新串成完整 MCU Cloud lifecycle；本篇只建立 SNTP 这一环。

## 15. Stage 36 的完整调用链

把已经出现的函数按真实执行顺序重新串起来：

```mermaid
flowchart TD
    A["sntp_example_init()"] --> B["sntp_setoperatingmode(POLL)"]
    B --> C["configure server source"]
    C --> D["sntp_init()"]
    D --> E["udp_new_ip_type() + udp_recv(sntp_recv)"]
    E --> F["sntp_request()"]
    F --> G{"DNS name?"}
    G -->|"yes"| H["dns_gethostbyname() / sntp_dns_found()"]
    G -->|"no"| I["configured server address"]
    H --> J["sntp_send_request()"]
    I --> J
    J --> K["UDP/123 request + receive timeout"]
    K --> L["sntp_recv()"]
    L --> M["sntp_process()"]
    M --> N["SNTP_SET_SYSTEM_TIME_NTP()"]
    N --> O["SNTP_UPDATE_DELAY"]
    O --> F
```

Stage 36 到这里建立的是：**SNTP client 本身只负责获取和计算时间；Server 来源可以来自 DHCP、静态地址或 DNS，周期与失败恢复由 lwIP Timer 驱动，而真正的系统时钟写入属于平台 Port。**

下一篇 Stage 37 将转向设备主动访问云端的另一条高频路径：`httpc_get_file_dns()` → DNS → altcp/TCP 或 altcp/TLS → HTTP GET → Header/Body callback，把 HTTP/HTTPS Client 与 REST、配置拉取和 OTA 下载的网络侧基础接起来。

## 资料来源

<a id="source-s1"></a>
### [S1] lwIP upstream SNTP example
- 类型：用户提供源码快照 + upstream 对照
- 版本：用户提供 `lwip.zip`；相关文件 blob 与 upstream commit `d08f4773edd0182b7910fc8f046eed82ffcd67c9` 一致
- 定位：`contrib/examples/sntp/sntp_example.c`：`sntp_example_init()`、`sntp_set_system_time()`
- URL/文档：[lwIP sntp_example.c](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/sntp/sntp_example.c)
- 使用位置：“真实入口”“DHCP/静态 Server 选择”“example 的时间打印行为”
- 支撑内容：证明 upstream example 怎样启动 SNTP，以及 example 只打印收到的时间而不代表通用 MCU RTC Port

<a id="source-s2"></a>
### [S2] lwIP SNTP client implementation
- 类型：用户提供源码快照 + upstream 对照
- 版本：同上
- 定位：`src/apps/sntp/sntp.c`：`sntp_init()`、`sntp_request()`、`sntp_dns_found()`、`sntp_send_request()`、`sntp_recv()`、`sntp_process()`、`sntp_retry()`、`sntp_try_next_server()`、`dhcp_set_ntp_servers()`
- URL/文档：[lwIP sntp.c](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/apps/sntp/sntp.c)
- 使用位置：Stage 36 Source-driven 主调用链
- 支撑内容：SNTP UDP PCB、DNS bridge、48-byte request/response、KoD、Timer、系统时间 Port 与 Server failover 的直接实现证据

<a id="source-s3"></a>
### [S3] lwIP SNTP public API 与 compile-time options
- 类型：用户提供源码快照 + upstream 对照
- 版本：同上
- 定位：`src/include/lwip/apps/sntp.h`、`src/include/lwip/apps/sntp_opts.h`
- URL/文档：[lwIP sntp.h](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/apps/sntp.h)、[lwIP sntp_opts.h](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/apps/sntp_opts.h)
- 使用位置：“DHCP/DNS 开关”“系统时间 hook”“timeout/update/retry 默认值”
- 支撑内容：限定当前 upstream 的默认配置与 Port contract，避免把实现默认值写成协议规定

<a id="source-s4"></a>
### [S4] lwIP DHCP NTP Server integration
- 类型：目标版本上游源码
- 版本：同上
- 定位：`src/include/lwip/opt.h`：`LWIP_DHCP_GET_NTP_SRV`；`src/include/lwip/dhcp.h`：`dhcp_set_ntp_servers()` contract；`src/core/ipv4/dhcp.c`：DHCP Option 42 parser
- URL/文档：[lwIP dhcp.h](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/dhcp.h)、[lwIP dhcp.c](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/ipv4/dhcp.c)
- 使用位置：“DHCP Server 地址怎样进入 SNTP”
- 支撑内容：证明 DHCP-NTP 需要 compile-time option 与 runtime servermode 两层条件

<a id="source-s5"></a>
### [S5] RFC 4330 — Simple Network Time Protocol Version 4（历史兼容背景）
- 类型：已废止的历史协议文档
- 版本：RFC 4330，2006；已被 RFC 5905 取代，但当前 lwIP SNTP 源码仍明确以 RFC 4330 描述其 minimal SNTPv4 implementation
- URL/文档：[RFC 4330](https://www.rfc-editor.org/rfc/rfc4330.html)
- 使用位置：“阅读源码前的版本边界”“解释目标源码中的历史 RFC 引用”
- 支撑内容：说明目标 lwIP 注释为何仍引用 SNTPv4 文档；当前协议语义以 RFC 5905 为主

<a id="source-s6"></a>
### [S6] RFC 5905 — Network Time Protocol Version 4
- 类型：IETF Standards Track / 当前主要规范锚点
- 版本：RFC 5905，2010
- URL/文档：[RFC 5905](https://www.rfc-editor.org/rfc/rfc5905.html)
- 使用位置：SNTP/NTP 初学者基线、48-byte base packet / UDP 123、Mode/Timestamp、KoD 与 round-trip compensation
- 支撑内容：RFC 5905 明确取代 RFC 4330，并提供当前 NTPv4 on-wire format、timestamp、client/server mode 与 KoD 等规范语义

<a id="source-s7"></a>
### [S7] Mbed TLS 2.28 X.509 time verification
- 类型：TLS library 官方版本化 API 文档
- 版本：Mbed TLS 2.28.x API documentation
- URL/文档：[Mbed TLS 2.28 X.509 API](https://mbed-tls.readthedocs.io/projects/api/en/v2.28.9/api/file/x509_8h/)、[Mbed TLS external time dependencies](https://mbed-tls.readthedocs.io/en/latest/kb/development/what-external-dependencies-does-mbedtls-rely-on/)
- 使用位置：“SNTP 为什么与 TLS/Cloud 有工程关系”
- 支撑内容：X.509 time helpers 使用系统时间判断 `valid_from`/`valid_to`；启用相应 time/date 配置时，证书验证会标记 expired/future

<a id="source-s8"></a>
### [S8] lwIP Multithreading / Common pitfalls
- 类型：目标版本上游 Doxygen 文档
- 版本：commit `d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- 定位：`doc/doxygen/main_page.h`：`Multithreading`、`Common pitfalls`
- URL/文档：[lwIP multithreading guidance](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/doc/doxygen/main_page.h)
- 使用位置：“SNTP Raw API 的 RTOS execution context”
- 支撑内容：说明 callback-style/core API 在 OS mode 下应由 TCPIP thread 或 core locking 保护

<a id="source-s9"></a>
### [S9] Cisco Simple Network Time Protocol
- 类型：厂商官方工程文档
- 版本：Cisco IOS XE System Management Configuration Guide，访问于 2026-10-03
- URL/文档：[Cisco Simple Network Time Protocol](https://www.cisco.com/c/en/us/td/docs/routers/ios-xe/system-management/system-management/m_bsm-sntpv4.html)
- 使用位置：SNTP/NTP 工程背景与初学者基线
- 支撑内容：提供 SNTP 作为简化 client-only NTP、与 NTP 的职责差异及工程使用背景，作为 RFC 之前的快速阅读入口
