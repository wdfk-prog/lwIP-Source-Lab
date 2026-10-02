<meta name="referrer" content="no-referrer" />

# 教程 29：从 `lcp_open()` 到 `np_up()`——LCP、PAP/CHAP、IPCP、IPv6CP 与 PPP 协商状态机

> 摘要：沿 PPP phase 与 generic FSM 追踪 LCP 配置协商、PAP/CHAP 认证、Network phase、IPCP/IPv6CP 配置与网络协议启用，明确各层职责与 RUNNING 条件。

[TOC]

Stage 28 已经把 PPPoS 串口字节流恢复成 PPP frame，并把 frame 交给 `ppp_input()`。Stage 29 从 `ppp_start()` 中已经出现的 `lcp_open()` / `lcp_lowerup()` 继续，追踪 PPP 为什么不会一收到串口字节就直接允许 IPv4/IPv6，而要依次经过 LCP、可选认证和 Network Control Protocol。[S1](#source-s1)[S3](#source-s3)

本篇把两层状态机同时保留：整个 session 的 `PPP_PHASE_*`，以及 LCP/IPCP/IPv6CP 共用的 generic `fsm`。二者层次不同，不能混成一套状态。

## 1. 当前 example 打开 PAP/CHAP，但是否实际认证由协商结果决定

当前 `contrib/examples/example_app/lwipopts.h`：[S2](#source-s2)

```c
#define PAP_SUPPORT             1
#define CHAP_SUPPORT            1
#define MSCHAP_SUPPORT          0
```

继续阅读 `pppos_example_init()`：PPPoS example 只有在定义测试宏时才主动设置 CHAP credential。[S2](#source-s2)

```c
#ifdef LWIP_PPP_CHAP_TEST
  ppp_set_auth(ppp, PPPAUTHTYPE_CHAP, "lwip", "mysecret");
#endif
```

所以“编译了 PAP/CHAP”与“当前 peer 一定要求认证”不是一回事。真正是否进入 PAP/CHAP，取决于 LCP negotiation 后双方接受的 authentication protocol option。[S1](#source-s1)[S3](#source-s3)

## 2. `ppp_start()` 同时触发 LCP open 与 lower-up

Stage 28 的终点是：[S1](#source-s1)

```c
void ppp_start(ppp_pcb *pcb) {
  new_phase(pcb, PPP_PHASE_ESTABLISH);
  lcp_open(pcb);
  lcp_lowerup(pcb);
}
```

这里有两个不同事件：

- `lcp_open()`：上层说“这个协议允许开始”；
- `lcp_lowerup()`：下层 serial link 已可用。

二者都进入 generic FSM，但对应不同事件入口。

## 3. LCP/IPCP/IPv6CP 都复用同一套 generic FSM

`fsm.h` 定义 10 个状态：[S1](#source-s1)

```text
INITIAL
STARTING
CLOSED
STOPPED
CLOSING
STOPPING
REQSENT
ACKRCVD
ACKSENT
OPENED
```

核心 negotiation 主要发生在：

```mermaid
stateDiagram-v2
    [*] --> INITIAL
    INITIAL --> STARTING: fsm_open while lower down
    INITIAL --> CLOSED: fsm_lowerup
    CLOSED --> REQSENT: fsm_open / send Configure-Request
    REQSENT --> ACKRCVD: receive valid Configure-Ack
    REQSENT --> ACKSENT: accept peer Configure-Request
    ACKRCVD --> OPENED: accept peer Configure-Request / send Ack
    ACKSENT --> OPENED: receive valid Configure-Ack
    OPENED --> REQSENT: renegotiation event
    OPENED --> STOPPING: close/lower-down path
```

真实 `fsm.c` 还处理 Nak、Reject、Terminate、Code-Reject、timeout/retry 等分支。本图只保留理解 LCP/IPCP/IPv6CP 正常打开所需的主迁移。[S1](#source-s1)[S3](#source-s3)

## 4. LCP `protent` 把 protocol number 接到 FSM

`ppp_input()` 读到 `PPP_LCP` 后，通过 `protocols[]` 找到 `lcp_protent`。该表把 generic PPP dispatcher 与 LCP 实现连接起来：[S1](#source-s1)

```c
const struct protent lcp_protent = {
    PPP_LCP,
    lcp_init,
    lcp_input,
    lcp_protrej,
    lcp_lowerup,
    lcp_lowerdown,
    lcp_open,
    lcp_close,
#if PRINTPKT_SUPPORT
    lcp_printpkt,
#endif
#if PPP_DATAINPUT
    NULL,
#endif
#if PRINTPKT_SUPPORT
    "LCP",
    NULL,
#endif
#if PPP_OPTIONS
    lcp_option_list,
    NULL,
#endif
#if DEMAND_SUPPORT
    NULL,
    NULL
#endif
};
```

因此 RX bridge 是：

```mermaid
flowchart LR
    A["ppp_input(): protocol=PPP_LCP"] --> B["protocols[] lookup"]
    B --> C["lcp_protent.input"]
    C --> D["lcp_input()"]
    D --> E["fsm_input(&lcp_fsm)"]
```

## 5. LCP 真正协商的是 link-level 能力

LCP 不分配 IPv4 address。它协商的是 PPP link 本身的参数，例如 MRU、async map、authentication protocol、Protocol-Field-Compression、Address-and-Control-Field-Compression 等。[S1](#source-s1)[S3](#source-s3)

当 LCP FSM 到达 `OPENED`，callback `lcp_up()` 被调用。`lcp_up()` 根据双方 option 结果配置 PPPoS framing：[S1](#source-s1)

```c
mtu = ho->neg_mru? ho->mru: PPP_DEFMRU;
mru = go->neg_mru? LWIP_MAX(wo->mru, go->mru): PPP_DEFMRU;
ppp_netif_set_mtu(pcb, LWIP_MIN(LWIP_MIN(mtu, mru), ao->mru));

ppp_send_config(pcb, mtu,
                (ho->neg_asyncmap? ho->asyncmap: 0xffffffff),
                ho->neg_pcompression, ho->neg_accompression);
ppp_recv_config(pcb, mru,
                (pcb->settings.lax_recv? 0: go->neg_asyncmap? go->asyncmap: 0xffffffff),
                go->neg_pcompression, go->neg_accompression);
```

继续阅读 `lcp_up()`：完成 framing 参数下发后才调用 `link_established()`。[S1](#source-s1)

```c
link_established(pcb);
```

这就是 PPP phase 从“链路协商”切到“认证/网络协商”的桥。

## 6. `link_established()` 把 phase 切到 AUTHENTICATE

进入 `link_established()` 后，先通知其他 protocol“LCP 已 up”，再根据 LCP negotiation 结果决定认证方向：[S1](#source-s1)

```c
new_phase(pcb, PPP_PHASE_AUTHENTICATE);
auth = 0;
```

如果对端要求本端认证，`ho` 中相应 flag 会触发：

```text
PAP  -> upap_authwithpeer()
CHAP -> chap_auth_with_peer()
EAP  -> eap_authwithpeer()
```

如果本端作为 server 要求 peer 认证，则使用 `go` 中协商出的方向触发 `upap_authpeer()` / `chap_auth_peer()` 等。[S1](#source-s1)

没有任何认证待完成时，直接进入 `network_phase()`。

## 7. PAP：credential 直接进入 Authenticate-Request

PAP client 入口 `upap_authwithpeer()` 保存 username/password，并在 lower layer ready 后调用 `upap_sauthreq()` 发送 Authenticate-Request：[S1](#source-s1)[S4](#source-s4)

```c
void upap_authwithpeer(ppp_pcb *pcb, const char *user, const char *password) {
    if(!user || !password)
        return;

    pcb->upap.us_user = user;
    pcb->upap.us_userlen = (u8_t)LWIP_MIN(strlen(user), 0xff);
    pcb->upap.us_passwd = password;
    pcb->upap.us_passwdlen = (u8_t)LWIP_MIN(strlen(password), 0xff);
    pcb->upap.us_transmits = 0;

    if (pcb->upap.us_clientstate == UPAPCS_INITIAL ||
        pcb->upap.us_clientstate == UPAPCS_PENDING) {
        pcb->upap.us_clientstate = UPAPCS_PENDING;
        return;
    }

    upap_sauthreq(pcb);
}
```

PAP 的协议语义是 credential exchange，不提供 CHAP 那种 challenge-response。RFC 1334 也明确把 PAP 与 CHAP 作为不同安全性质的认证机制。[S4](#source-s4)

## 8. PAP Ack 最终进入 `auth_withpeer_success()`

当本端收到 Authenticate-Ack，PAP handler 把 client state 切到 OPEN，并调用：

```text
auth_withpeer_success(pcb, PPP_PAP, 0)
```

`auth_withpeer_success()` 清除对应 `auth_pending` bit。只有所有需要的认证都完成时，才进入 `network_phase()`。[S1](#source-s1)

```text
PAP success
  or CHAP success
        ↓
auth_pending 清相应 bit
        ↓
auth_pending == 0 ?
        ↓ yes
network_phase()
```

## 9. CHAP：Challenge → Response → Success/Failure

CHAP 与 PAP 最大差异是 peer 先发 Challenge，本端根据 challenge、identifier、secret 生成 Response，peer 再返回 Success/Failure。[S1](#source-s1)[S5](#source-s5)

当前 `chap_input()` 直接按 code 分发：[S1](#source-s1)

```c
switch (code) {
case CHAP_CHALLENGE:
    chap_respond(pcb, id, pkt, len);
    break;
case CHAP_RESPONSE:
    chap_handle_response(pcb, id, pkt, len);
    break;
case CHAP_SUCCESS:
case CHAP_FAILURE:
    chap_handle_status(pcb, code, id, pkt, len);
    break;
}
```

client 收到 `CHAP_SUCCESS` 后，`chap_handle_status()` 最终调用：[S1](#source-s1)

```c
auth_withpeer_success(pcb, PPP_CHAP, pcb->chap_client.digest->code);
```

认证失败则进入 `auth_withpeer_fail()`，并最终导致 PPP link 关闭，而不是继续打开 IPCP/IPv6CP。

## 10. Authentication Protocol 是 LCP option，不是“PPP frame type 自己决定”

PAP/CHAP packet 确实各有 PPP Protocol value，但是否要求某种认证是在 LCP negotiation 中通过 Authentication-Protocol option 达成的。[S3](#source-s3)[S4](#source-s4)[S5](#source-s5)

因此正确顺序是：

```text
LCP Configure negotiation
        ↓
双方确认 authentication option
        ↓
LCP OPENED
        ↓
AUTHENTICATE phase
        ↓
PAP / CHAP packet exchange
```

而不是“先收到 PAP frame，再决定要不要 PAP”。

## 11. `network_phase()` 不直接配置 IP，而是启动 NCP

认证完成后 `network_phase()` 调用 `start_networks()`，再进入 `continue_networks()`。[S1](#source-s1)

`start_networks()` 先执行 phase 切换；在 CCP/ECP/MPPE 的条件分支处理后，函数尾部只有满足当前加密条件才调用 `continue_networks()`。下面分别保留这两个连续源码片段：[S1](#source-s1)

继续阅读 `start_networks()` 的 phase 切换：

```c
new_phase(pcb, PPP_PHASE_NETWORK);
```

继续阅读 `start_networks()` 的函数尾部：

```c
if (1
#if ECP_SUPPORT
    && !ecp_gotoptions[unit].required
#endif
#if MPPE_SUPPORT
    && !pcb->ccp_gotoptions.mppe
#endif
    )
  continue_networks(pcb);
```

`continue_networks()` 遍历 `protocols[]`，对真正的 network protocols 调用各自 `open()`：[S1](#source-s1)

```c
for (i = 0; (protp = protocols[i]) != NULL; ++i)
    if (protp->protocol < 0xC000
        && protp->open != NULL) {
        (*protp->open)(pcb);
        ++pcb->num_np_open;
    }
```

对于本篇主线，就是：

```text
IPCP  -> ipcp_open()
IPv6CP -> ipv6cp_open()
```

## 12. IPCP 与 LCP 复用同一个 `fsm_open()`

`ipcp_open()` 本身只有：[S1](#source-s1)

```c
static void ipcp_open(ppp_pcb *pcb) {
    fsm_open(&pcb->ipcp_fsm);
}
```

收到 IPCP frame 时：

```c
static void ipcp_input(ppp_pcb *pcb, u_char *p, int len) {
    fsm_input(&pcb->ipcp_fsm, p, len);
}
```

这和 LCP 的 control-flow skeleton 完全相同：差异主要在各 protocol 的 option callbacks，而不是 FSM engine 本身。

## 13. IPCP 协商 IPv4 network-layer 参数

IPCP 的典型 option 包括 local/remote IPv4 address、VJ compression、DNS server request 等。[S1](#source-s1)[S6](#source-s6)

它不处理 serial escaping，也不重新协商 MRU/ACCM——那些属于 LCP。

正常路径：

```mermaid
flowchart LR
    A["network_phase()"] --> B["ipcp_open()"]
    B --> C["fsm_open(ipcp_fsm)"]
    C --> D["Configure-Request"]
    D --> E["Ack/Nak/Reject exchange"]
    E --> F["FSM OPENED"]
    F --> G["ipcp_up()"]
    G --> H["sifaddr() / sifup()"]
    H --> I["np_up(PPP_IP)"]
```

Stage 30 会继续展开 `sifaddr()`、DNS 与 route。

## 14. IPv6CP 不是 DHCPv6，也不分配完整 IPv6 prefix

`ipv6cp_open()` 同样调用 generic FSM：[S1](#source-s1)

```c
static void ipv6cp_open(ppp_pcb *pcb) {
    fsm_open(&pcb->ipv6cp_fsm);
}
```

当前 lwIP `ipv6cp_init()` 默认协商 Interface-Identifier：[S1](#source-s1)[S7](#source-s7)

```c
wo->accept_local = 1;
wo->neg_ifaceid = 1;
ao->neg_ifaceid = 1;
```

IPv6CP 解决的是 PPP link 上 IPv6 network control，例如 Interface-Identifier。它不是 SLAAC RA，也不是 DHCPv6 server/client。[S7](#source-s7)

## 15. `ipv6cp_up()` 先生成 link-local，再 `np_up(PPP_IPV6)`

IPv6CP FSM 到 OPENED 后，`ipv6cp_up()` 检查双方 Interface-Identifier，然后通过 `sif6addr()` 设置本地 link-local，再 `sif6up()`：[S1](#source-s1)

```c
if (!sif6addr(f->pcb, go->ourid, ho->hisid)) {
    ipv6cp_close(f->pcb, "Interface configuration failed");
    return;
}

if (!sif6up(f->pcb)) {
    ipv6cp_close(f->pcb, "Interface configuration failed");
    return;
}

np_up(f->pcb, PPP_IPV6);
pcb->ipv6cp_is_up = 1;
```

所以“IPv6CP OPENED”与“PPP session 整体 RUNNING”之间仍隔着 `sif6up()` / `np_up()`。

## 16. `np_up()` 是 PPP high-level RUNNING 的关键桥

IPCP 或 IPv6CP 任一个 network protocol 首次 up 时都会调用 `np_up()`。[S1](#source-s1)

下面是 `np_up()` 在不启用 idle/max-connect/max-octets 附加定时器时的执行路径阅读版；它裁掉的是当前主线不执行的条件编译分支，不是未经修改的完整上游函数：[S1](#source-s1)

```c
if (pcb->num_np_up == 0) {
    new_phase(pcb, PPP_PHASE_RUNNING);
}
++pcb->num_np_up;
```

因此：

```text
IPCP up first
    -> PPP_PHASE_RUNNING
    -> num_np_up = 1
IPv6CP later up
    -> phase already RUNNING
    -> num_np_up = 2
```

如果只编译/启用 IPv4，一个 IPCP up 就足以让 session 进入 RUNNING。

## 17. PPP phase 的主线状态图

当前实现的 phase 定义比基础 RFC phase 更细，包括 HOLDOFF、INITIALIZE、DISCONNECT 等 implementation state。[S1](#source-s1)

主成功路径可以压缩为：

```mermaid
stateDiagram-v2
    [*] --> DEAD
    DEAD --> INITIALIZE: ppp_connect()
    INITIALIZE --> ESTABLISH: ppp_start()
    ESTABLISH --> AUTHENTICATE: LCP OPENED
    AUTHENTICATE --> NETWORK: auth complete or no auth
    NETWORK --> RUNNING: first np_up()
    RUNNING --> TERMINATE: lcp_close / error
    TERMINATE --> DISCONNECT: link terminated
    DISCONNECT --> DEAD: link adapter end
```

这里 `AUTHENTICATE` 可以非常短：如果 LCP 没有协商出任何认证，`link_established()` 会直接进入 `network_phase()`。[S1](#source-s1)

## 18. 为什么收到 IP packet 前要检查 phase/LCP state

`ppp_input()` 对 RX 做两层 gate：[S1](#source-s1)

继续阅读 `ppp_input()`。第一层：LCP 未 OPEN 时，除 LCP 外的 packet 全部丢弃：

```c
if (protocol != PPP_LCP && pcb->lcp_fsm.state != PPP_FSM_OPENED) {
    goto drop;
}
```

继续阅读 `ppp_input()`。第二层：认证阶段及之前，只允许 LCP/LQR/PAP/CHAP/EAP：[S1](#source-s1)

```c
if (pcb->phase <= PPP_PHASE_AUTHENTICATE
   && !(protocol == PPP_LCP
        || protocol == PPP_PAP
        || protocol == PPP_CHAP)) {
    goto drop;
}
```

所以即使串口上已经出现合法 `PPP_IP` frame，在 authentication 尚未完成时也不会被送进 `ip4_input()`。

## 19. LCP option negotiation 怎样反向改变 Stage 28 的 framing

Stage 28 的 `pppos->pcomp`、`accomp`、`in_accm/out_accm` 不是固定常量。LCP OPEN 后，`lcp_up()` 调用：

```text
ppp_send_config()
    -> link_cb->send_config()
    -> pppos_send_config()

ppp_recv_config()
    -> link_cb->recv_config()
    -> pppos_recv_config()
```

因此 protocol negotiation 的结果会直接改变 serial frame 编码方式。[S1](#source-s1)

这就是为什么 PPP Core 与 PPPoS framing 不能完全割裂：LCP control plane 会配置 link adapter data path。

## 20. 正常协商的完整协议时序

```mermaid
sequenceDiagram
    participant A as Local PPP
    participant B as Peer PPP
    A->>B: LCP Configure-Request
    B->>A: LCP Configure-Request
    A-->>B: Configure-Ack/Nak/Reject
    B-->>A: Configure-Ack/Nak/Reject
    Note over A,B: LCP reaches OPENED
    alt authentication negotiated
        B->>A: PAP/CHAP exchange
        A-->>B: authentication result
    end
    A->>B: IPCP Configure-Request
    B->>A: IPCP Configure-Request
    A-->>B: Ack/Nak/Reject
    B-->>A: Ack/Nak/Reject
    A->>B: IPv6CP Configure-Request
    B->>A: IPv6CP Configure-Request
    A-->>B: Ack/Nak/Reject
    B-->>A: Ack/Nak/Reject
    Note over A,B: first NCP up -> PPP_PHASE_RUNNING
```

具体 PAP/CHAP、IPCP、IPv6CP 可以只启用其中一部分；图表示的是当前实现允许形成的组合，而不是每条 PPP link 都必然包含全部协议。[S1](#source-s1)

## 21. 当前 example 的认证能力边界

当前 example config：[S2](#source-s2)

| 能力 | 当前 compile config |
| --- | --- |
| PAP | enabled |
| CHAP | enabled |
| MSCHAP | disabled |
| VJ | disabled |
| CCP | disabled |
| PPPoS | enabled |

因此本篇重点只把 PAP 与 basic CHAP 作为当前可执行能力解释。源码树里存在更多 EAP/MSCHAP/CCP/MPPE 路径，但当前 example config 不应被描述成默认都启用。

## 22. Stage 29 完整调用链

```mermaid
flowchart TD
    A["ppp_start()"] --> B["lcp_open + lcp_lowerup"]
    B --> C["generic FSM"]
    C --> D["LCP OPENED -> lcp_up()"]
    D --> E["link_established()"]
    E --> F{"auth negotiated?"}
    F -->|PAP| G["upap_authwithpeer()"]
    F -->|CHAP| H["chap_auth_with_peer()"]
    F -->|no| I["network_phase()"]
    G --> I
    H --> I
    I --> J["continue_networks()"]
    J --> K["ipcp_open() / ipv6cp_open()"]
    K --> L["NCP generic FSM"]
    L --> M["ipcp_up() / ipv6cp_up()"]
    M --> N["np_up()"]
    N --> O["PPP_PHASE_RUNNING"]
```

## 23. 当前实现边界

1. PAP/CHAP 是否实际执行由 LCP negotiation 决定，不由 compile flag 单独决定；
2. PPP high-level phase 与 per-protocol generic FSM 是两层状态机；
3. LCP 负责 link configuration，不负责 IPv4/IPv6 address；
4. PAP 与 CHAP 是不同认证协议，PAP credential exchange 不具备 CHAP challenge-response 语义；
5. IPCP 与 IPv6CP 复用 generic FSM，但协商 option 集不同；
6. IPv6CP 主要协商 IPv6 over PPP link 参数/Interface-Identifier，不等于 DHCPv6/SLAAC；
7. `PPP_PHASE_RUNNING` 在第一个 network protocol `np_up()` 时进入，不要求 IPv4 与 IPv6 都已经 up；
8. 地址写入 `netif`、DNS/default route、断线与 reconnect 留到 Stage 30。

## 资料来源

<a id="source-s1"></a>
### [S1] lwIP PPP LCP/Auth/NCP/FSM 源码
- 类型：目标版本上游源码
- 版本：commit `d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- 定位：`src/netif/ppp/ppp.c`、`fsm.c`、`lcp.c`、`auth.c`、`upap.c`、`chap-new.c`、`ipcp.c`、`ipv6cp.c`；`src/include/netif/ppp/fsm.h`、`ppp.h`、`ppp_impl.h`
- URL/文档：[lwIP PPP source](https://github.com/lwip-tcpip/lwip/tree/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/netif/ppp)
- 使用位置：“PPP phase”“generic FSM”“LCP up”“PAP/CHAP success”“network_phase”“IPCP/IPv6CP”“np_up”
- 支撑内容：证明当前 pinned PPP control-plane 的真实状态机、callback 与 protocol transition

<a id="source-s2"></a>
### [S2] lwIP PPP example/config
- 类型：目标版本上游 example/config
- 版本：commit `d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- 定位：`contrib/examples/ppp/pppos_example.c`；`contrib/examples/example_app/lwipopts.h`
- URL/文档：[lwIP PPP examples](https://github.com/lwip-tcpip/lwip/tree/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/ppp)
- 使用位置：“PAP/CHAP compile config”“example credential 设置”
- 支撑内容：限定当前 example 实际启用的 PPP authentication/compression 能力

<a id="source-s3"></a>
### [S3] RFC 1661：The Point-to-Point Protocol (PPP)
- 类型：IETF 标准规范
- 版本：RFC 1661，1994
- URL/文档：[RFC 1661](https://www.rfc-editor.org/rfc/rfc1661.html)
- 使用位置：“LCP”“PPP phases”“Authentication-Protocol option”“NCP”
- 支撑内容：提供 PPP link establishment、authentication 与 network-layer protocol configuration 的规范语义

<a id="source-s4"></a>
### [S4] RFC 1334：PPP Authentication Protocols
- 类型：IETF 标准规范
- 版本：RFC 1334，1992
- URL/文档：[RFC 1334](https://www.rfc-editor.org/rfc/rfc1334.html)
- 使用位置：“PAP Authenticate-Request/Ack/Nak”“PAP credential exchange”
- 支撑内容：提供 PAP 的协议语义，并用于与 CHAP 的 challenge-response 区分

<a id="source-s5"></a>
### [S5] RFC 1994：PPP Challenge Handshake Authentication Protocol (CHAP)
- 类型：IETF 标准规范
- 版本：RFC 1994，1996
- URL/文档：[RFC 1994](https://www.rfc-editor.org/rfc/rfc1994.html)
- 使用位置：“CHAP Challenge/Response/Success/Failure”
- 支撑内容：提供 CHAP challenge-response authentication 的标准报文与状态语义

<a id="source-s6"></a>
### [S6] RFC 1332：The PPP Internet Protocol Control Protocol (IPCP)
- 类型：IETF 标准规范
- 版本：RFC 1332，1992
- URL/文档：[RFC 1332](https://www.rfc-editor.org/rfc/rfc1332.html)
- 使用位置：“IPCP”“IPv4 address negotiation”“IP-Compression-Protocol”
- 支撑内容：提供 IPCP 的 Network Control Protocol 语义，用于对照 lwIP `ipcp.c`

<a id="source-s7"></a>
### [S7] RFC 5072：IP Version 6 over PPP
- 类型：IETF 标准规范
- 版本：RFC 5072，2007
- URL/文档：[RFC 5072](https://www.rfc-editor.org/rfc/rfc5072.html)
- 使用位置：“IPv6CP”“Interface-Identifier”“IPv6 over PPP”
- 支撑内容：提供 IPv6CP 与 IPv6 datagram over PPP 的标准语义，避免把 IPv6CP 与 DHCPv6/SLAAC 混淆
