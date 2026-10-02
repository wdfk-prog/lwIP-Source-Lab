<meta name="referrer" content="no-referrer" />

# 教程 17：从 `IP_ADD_MEMBERSHIP` 到 `igmp_input()`——IPv4 Multicast、IGMPv2、MAC Filter 与组成员状态机

> 摘要：从 RTP Socket 的 IP_ADD_MEMBERSHIP 入口追踪 IGMPv2 加组、Report/Query/Leave、100 ms Timer、报告抑制与 multicast MAC 映射。

[TOC]

Stage 16 已经把 IPv4 fragmentation/reassembly 的 MTU 边界闭环。接下来进入另一种完全不同的“一个 packet 对应谁”的问题：**multicast packet 不是发给一个明确的 unicast host，而是发给一个 group；Host 必须告诉本地链路上的 multicast router 自己正在监听哪些组，同时网卡/Driver 还要决定哪些 multicast Ethernet frame 能进入接收路径。**

本篇使用 upstream 自带的 RTP example 作为真实应用入口，而不是从 `igmp_joingroup_netif()` 中间函数凭空开始：[S1](#source-s1)

```text
rtp_recv_thread()
    ↓
lwip_setsockopt(IP_ADD_MEMBERSHIP)
    ↓
tcpip_callback / Core Lock
    ↓
lwip_setsockopt_impl()
    ↓
igmp_joingroup()
    ↓
igmp_joingroup_netif()
    ↓
Membership Report + report timer
    ↓
Router Query / other host Report
    ↓
igmp_input()
    ↓
state / timer / suppression
    ↓
IP_DROP_MEMBERSHIP
    ↓
Leave Group + resource cleanup
```

当前源码基线仍为 `d08f4773edd0182b7910fc8f046eed82ffcd67c9`。[S1](#source-s1)

本文只解释当前 lwIP `igmp.c` 的 IPv4 host-side IGMP 行为。IPv6 MLD、IGMPv3 source filtering、multicast routing protocol 与交换机 IGMP Snooping 不展开成第二条主线。

## 1. Multicast 的第一层边界：UDP Port 和 Multicast Group 是两个不同筛选条件

普通 UDP unicast 常见模型是：

```text
Destination IPv4
+ Destination UDP Port
→ 找到本机 UDP PCB / Socket
```

Multicast 又多了一层 group membership：

```text
Destination IPv4 multicast group
        ↓
这个 netif 是否加入该 group？
        ↓
IPv4 packet 是否允许进入本机协议栈
        ↓
UDP destination port
        ↓
Socket / PCB
```

所以这三个动作不能混为一谈：

| 动作 | 决定什么 |
| --- | --- |
| `bind(..., UDP port)` | 哪个 UDP endpoint 接收某个 port 的 datagram |
| `IP_ADD_MEMBERSHIP` | 当前 Host/interface 是否加入一个 IPv4 multicast group |
| MAC multicast filter | Ethernet MAC/Driver 是否接收映射到该 multicast MAC 的 frame |

只 bind UDP port 并不等于加入 multicast group；加入 group 也不等于自动 bind 某个 UDP port。

## 2. 当前 example 已经启用 IGMP Core，但没有默认加入业务组

当前 `example_app/lwipopts.h` 定义：[S1](#source-s1)

```c
#define LWIP_IGMP                  LWIP_IPV4
```

继续看 Unix TAP Port 的 `tapif_init()`：它初始化 `netif` 时还会显式声明 IGMP capability。[S1](#source-s1)

```c
netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP | NETIF_FLAG_IGMP;
```

因此只要 IPv4 开启，当前 Host example 具备 IGMP Core 能力。但这不代表它自动加入任意业务 multicast group。

真正加入业务组需要应用发起 join。upstream RTP example 正好提供了这条入口。

## 3. 真实应用入口：`rtp_recv_thread()` 先创建 UDP Socket，再请求 `IP_ADD_MEMBERSHIP`

`contrib/apps/rtp/rtp.c` 的接收线程创建 UDP socket、bind 到 RTP port，然后构造 `struct ip_mreq`。[S1](#source-s1)

```c
sock = lwip_socket(AF_INET, SOCK_DGRAM, 0);
if (sock >= 0) {
  memset(&local, 0, sizeof(local));
  local.sin_family      = AF_INET;
  local.sin_port        = PP_HTONS(RTP_STREAM_PORT);
  local.sin_addr.s_addr = PP_HTONL(INADDR_ANY);

  if (lwip_bind(sock, (struct sockaddr *)&local, sizeof(local)) == 0) {
    ipmreq.imr_multiaddr.s_addr = rtp_stream_address;
    ipmreq.imr_interface.s_addr = PP_HTONL(INADDR_ANY);

    if (lwip_setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP,
                        &ipmreq, sizeof(ipmreq)) == 0) {
```

当前 RTP example 默认：

```c
#define RTP_STREAM_PORT             4000
#define RTP_STREAM_ADDRESS          inet_addr("232.0.0.0")
```

这里先只关注调用关系：

```text
Socket bind port 4000
        ↓
IP_ADD_MEMBERSHIP 232.0.0.0
```

前者建立 UDP endpoint，后者建立 multicast membership；两者是两个独立步骤。

## 4. `lwip_setsockopt()` 不一定直接在 application thread 修改 IGMP Core

Stage 6 和 Stage 11 已经解释 Socket/Netconn 与 `tcpip_thread` 的线程边界。IGMP join 正好把这套模型重新用一次。

进入 `lwip_setsockopt()`：[S1](#source-s1)

```c
#if LWIP_TCPIP_CORE_LOCKING
LOCK_TCPIP_CORE();
err = lwip_setsockopt_impl(s, level, optname, optval, optlen);
UNLOCK_TCPIP_CORE();
#else
cberr = tcpip_callback(lwip_setsockopt_callback,
                       &LWIP_SETGETSOCKOPT_DATA_VAR_REF(data));
if (cberr != ERR_OK) {
  LWIP_SETGETSOCKOPT_DATA_VAR_FREE(data);
  set_errno(err_to_errno(cberr));
  done_socket(sock);
  return -1;
}
sys_arch_sem_wait((sys_sem_t *)(LWIP_SETGETSOCKOPT_DATA_VAR_REF(data).completed_sem), 0);
#endif
```

当前系列默认关注的 `NO_SYS=0`、非 Core Locking 模型下：

```mermaid
sequenceDiagram
    participant APP as RTP application thread
    participant MBOX as tcpip_mbox
    participant CORE as tcpip_thread

    APP->>MBOX: tcpip_callback(lwip_setsockopt_callback)
    APP->>APP: wait completed_sem
    MBOX->>CORE: callback message
    CORE->>CORE: lwip_setsockopt_impl()
    CORE-->>APP: sys_sem_signal(completed_sem)
```

因此 `igmp_joingroup()` 最终在 lwIP Core execution context 中执行，不是两个线程同时直接改 `netif` 的 IGMP linked list。

## 5. 回调进入 `lwip_setsockopt_impl()`：`IP_ADD_MEMBERSHIP` 才映射到 `igmp_joingroup()`

`tcpip_thread` 执行 `lwip_setsockopt_callback()` 后进入 `lwip_setsockopt_impl()`。继续阅读 `IPPROTO_IP` 的 membership 分支：[S1](#source-s1)

```c
case IP_ADD_MEMBERSHIP:
case IP_DROP_MEMBERSHIP: {
  err_t igmp_err;
  const struct ip_mreq *imr = (const struct ip_mreq *)optval;
  ip4_addr_t if_addr;
  ip4_addr_t multi_addr;
  LWIP_SOCKOPT_CHECK_OPTLEN_CONN_PCB_TYPE(sock, optlen, struct ip_mreq, NETCONN_UDP);
  inet_addr_to_ip4addr(&if_addr, &imr->imr_interface);
  inet_addr_to_ip4addr(&multi_addr, &imr->imr_multiaddr);
  if (optname == IP_ADD_MEMBERSHIP) {
    if (!lwip_socket_register_membership(s, &if_addr, &multi_addr)) {
      err = ENOMEM;
      igmp_err = ERR_OK;
    } else {
      igmp_err = igmp_joingroup(&if_addr, &multi_addr);
    }
  } else {
    igmp_err = igmp_leavegroup(&if_addr, &multi_addr);
    lwip_socket_unregister_membership(s, &if_addr, &multi_addr);
  }
```

这里出现两个不同的“membership”对象：

1. Socket layer 自己记录这只 socket 加入过哪些 group，便于 socket close 时自动清理；
2. IGMP Core 的 `struct igmp_group` 记录某个 `netif` 对某个 multicast group 的协议状态。

前者不是 IGMP state machine 本身。

## 6. `igmp_joingroup()` 先决定在哪个 `netif` 上加入

`lwip_setsockopt_impl()` 调用 `igmp_joingroup()`。它遍历 `netif_list`，匹配应用指定的 interface address；当 `INADDR_ANY` 时，可以对符合条件的 IGMP-enabled interface 执行 join。[S1](#source-s1)

真正创建 group 对象和发送 report 的函数是：

```c
igmp_joingroup_netif(netif, groupaddr)
```

所以主线继续进入 `igmp_joingroup_netif()`。

## 7. 但在业务 join 之前，`lwip_init()` 与 `netif_add()` 已经完成两层初始化

不能把 `igmp_joingroup_netif()` 当成所有 IGMP 状态的起点。

第一层发生在 `lwip_init()`：[S1](#source-s1)

```c
#if LWIP_IGMP
igmp_init();
#endif /* LWIP_IGMP */
```

`igmp_init()` 只建立两个特殊地址：[S1](#source-s1)

```c
void
igmp_init(void)
{
  LWIP_DEBUGF(IGMP_DEBUG, ("igmp_init: initializing\n"));

  IP4_ADDR(&allsystems, 224, 0, 0, 1);
  IP4_ADDR(&allrouters, 224, 0, 0, 2);
}
```

第二层发生在 `netif_add()`。只要 Port 设置 `NETIF_FLAG_IGMP`，加入 `netif_list` 时会调用：[S1](#source-s1)

```c
#if LWIP_IGMP
if (netif->flags & NETIF_FLAG_IGMP) {
  igmp_start(netif);
}
#endif /* LWIP_IGMP */
```

因此业务应用执行 `IP_ADD_MEMBERSHIP` 前，IGMP module 和接口级基础状态已经存在。

## 8. `igmp_start()` 自动创建 224.0.0.1 all-systems group

进入 `igmp_start()`：[S1](#source-s1)

```c
err_t
igmp_start(struct netif *netif)
{
  struct igmp_group *group;

  group = igmp_lookup_group(netif, &allsystems);

  if (group != NULL) {
    group->group_state = IGMP_GROUP_IDLE_MEMBER;
    group->use++;

    if (netif->igmp_mac_filter != NULL) {
      netif->igmp_mac_filter(netif, &allsystems, NETIF_ADD_MAC_FILTER);
    }

    return ERR_OK;
  }

  return ERR_MEM;
}
```

`224.0.0.1` 是 all-systems group。当前实现把它固定放在每个 IGMP-enabled `netif` 的 group list 第一个位置，并在后续 Report 遍历中专门跳过它。[S1](#source-s1)[S3](#source-s3)

所以：

```text
NETIF_FLAG_IGMP
    ↓ netif_add()
igmp_start()
    ↓
224.0.0.1 group exists
```

不等于：

```text
所有 multicast group 都已加入
```

## 9. `struct igmp_group`：membership 是“每个 netif 一条 linked list”

当前 IGMP group 对象定义：[S1](#source-s1)

```c
struct igmp_group {
  struct igmp_group *next;
  ip4_addr_t         group_address;
  u8_t               last_reporter_flag;
  u8_t               group_state;
  u16_t              timer;
  u8_t               use;
};
```

字段分别承担：

| 字段 | 作用 |
| --- | --- |
| `group_address` | 当前 IPv4 multicast group |
| `group_state` | Non-Member / Delaying Member / Idle Member |
| `timer` | 等待发送 Membership Report 的倒计时 |
| `last_reporter_flag` | 当前 Host 是否认为自己是最后一个发送 Report 的成员 |
| `use` | 同一 group 在本机被多少调用者同时使用 |
| `next` | 同一个 `netif` 上的下一条 group membership |

`netif_igmp_data(netif)` 通过 `netif` client-data slot 保存 list head。这和 Stage 13 的 DHCP client data、Stage 15 总览中的 IPv6 neighbor state 都体现了同一个设计：运行时协议状态必须绑定到具体接口或具体 destination，而不能只放一个无边界的全局标志。

## 10. `igmp_lookup_group()`：第一次加入业务组时从 `MEMP_IGMP_GROUP` 分配对象

进入 `igmp_joingroup_netif()` 之前，它先调用 `igmp_lookup_group()`。如果 group 不存在，该函数分配一个新的 `struct igmp_group`：[S1](#source-s1)[S2](#source-s2)

```c
group = (struct igmp_group *)memp_malloc(MEMP_IGMP_GROUP);
if (group != NULL) {
  ip4_addr_set(&(group->group_address), addr);
  group->timer              = 0;
  group->group_state        = IGMP_GROUP_NON_MEMBER;
  group->last_reporter_flag = 0;
  group->use                = 0;
```

`MEMP_NUM_IGMP_GROUP` 默认值为 8，但具体项目可以通过配置覆盖。[S2](#source-s2)

这意味着 membership 数量同样是嵌入式资源预算的一部分。第 9 个 group 是否能加入，不能脱离当前 `lwipopts.h` 的 pool 配置讨论。

## 11. 进入 `igmp_joingroup_netif()`：join 同时触发三件事

从 `igmp_joingroup()` 的 call site 进入 `igmp_joingroup_netif()`。[S1](#source-s1)

```c
err_t
igmp_joingroup_netif(struct netif *netif, const ip4_addr_t *groupaddr)
{
  struct igmp_group *group;

  LWIP_ASSERT_CORE_LOCKED();

  LWIP_ERROR("igmp_joingroup_netif: attempt to join non-multicast address",
             ip4_addr_ismulticast(groupaddr), return ERR_VAL;);
  LWIP_ERROR("igmp_joingroup_netif: attempt to join on non-IGMP netif",
             netif->flags & NETIF_FLAG_IGMP, return ERR_VAL;);

  group = igmp_lookup_group(netif, groupaddr);
```

找到新 group 后，当前实现依次做：

```text
1. 必要时更新 MAC multicast filter
2. 立即发送 IGMPv2 Membership Report
3. 启动一个短 report timer，并进入 DELAYING_MEMBER
```

下面逐步展开。

## 12. 第一件事：`igmp_mac_filter(ADD)` 是 Core 到 Driver/MAC 的可选边界

继续阅读 `igmp_joingroup_netif()`：[S1](#source-s1)

```c
if ((group->use == 0) && (netif->igmp_mac_filter != NULL)) {
  netif->igmp_mac_filter(netif, groupaddr, NETIF_ADD_MAC_FILTER);
}
```

这里非常容易产生错误理解：

> IGMP join 不是“只发一个网络报文”。

对带硬件 multicast filter 的 Ethernet MAC，Driver 可以通过 `netif_set_igmp_mac_filter()` 安装 callback，使 lwIP Core 在 join/leave 时通知 Driver 添加或删除对应 multicast MAC filter。

但当前 Unix TAP Port 只设置 `NETIF_FLAG_IGMP`，并没有安装 `igmp_mac_filter` callback。因此在本系列 Linux TAP 环境里：

```text
netif->igmp_mac_filter == NULL
```

当前 join 不会执行硬件过滤器编程。[S1](#source-s1)

这属于 **Port 实现差异**，不是 IGMP 协议规定“无需 MAC filter”。实际 MCU Ethernet MAC 若默认只接收自身 unicast/broadcast，Driver 可能必须实现这个 callback，否则 IGMP 协议状态正确，multicast data frame 仍可能在硬件层就被丢掉。

## 13. 第二件事：join 立即发送一个 IGMPv2 Membership Report

继续阅读同一个 `igmp_joingroup_netif()`：[S1](#source-s1)

```c
IGMP_STATS_INC(igmp.tx_join);
igmp_send(netif, group, IGMP_V2_MEMB_REPORT);

igmp_start_timer(group, IGMP_JOIN_DELAYING_MEMBER_TMR);

group->group_state = IGMP_GROUP_DELAYING_MEMBER;
```

RFC 2236 要求 Host 加组时立即发送 unsolicited Membership Report，以尽快让 multicast router 知道本链路出现了 group member；随后还会延时再次 report，提高初始 report 丢失时的可靠性。[S4](#source-s4)

因此 join 的第一个网络可见证据不是 multicast data，而是 IGMP control packet。

## 14. 进入 `igmp_send()`：Report 到 group，Leave 到 224.0.0.2

`igmp_joingroup_netif()` 直接调用 `igmp_send()`。进入该函数：[S1](#source-s1)

```c
p = pbuf_alloc(PBUF_TRANSPORT, IGMP_MINLEN, PBUF_RAM);

if (p) {
  igmp = (struct igmp_msg *)p->payload;
  ip4_addr_copy(src, *netif_ip4_addr(netif));

  if (type == IGMP_V2_MEMB_REPORT) {
    dest = &(group->group_address);
    ip4_addr_copy(igmp->igmp_group_address, group->group_address);
    group->last_reporter_flag = 1;
  } else {
    if (type == IGMP_LEAVE_GROUP) {
      dest = &allrouters;
      ip4_addr_copy(igmp->igmp_group_address, group->group_address);
    }
  }
```

当前行为和 RFC 2236 对应：[S4](#source-s4)

| IGMP message | IPv4 destination |
| --- | --- |
| General Query | `224.0.0.1` all-systems |
| Group-Specific Query | 被查询 group |
| Membership Report | 被报告 group |
| Leave Group | `224.0.0.2` all-routers |

`last_reporter_flag=1` 也不是装饰字段：leave 时是否需要发送 Leave Group 就依赖它。

## 15. `igmp_send()` 生成 8-byte IGMPv2 Header，并把 TTL 固定为 1

继续阅读 `igmp_send()`：[S1](#source-s1)

```c
if ((type == IGMP_V2_MEMB_REPORT) || (type == IGMP_LEAVE_GROUP)) {
  igmp->igmp_msgtype  = type;
  igmp->igmp_maxresp  = 0;
  igmp->igmp_checksum = 0;
  igmp->igmp_checksum = inet_chksum(igmp, IGMP_MINLEN);

  igmp_ip_output_if(p, &src, dest, netif);
}
```

然后 `igmp_ip_output_if()` 调用 IPv4 output：[S1](#source-s1)

```c
return ip4_output_if_opt(p, src, dest, IGMP_TTL, 0,
                         IP_PROTO_IGMP, netif, ra, ROUTER_ALERTLEN);
```

当前实现还插入 IPv4 Router Alert option，并使用 `IGMP_TTL=1`，让 IGMP control traffic 保持在本地链路范围。[S1](#source-s1)[S4](#source-s4)

## 16. IPv4 multicast 不查 ARP：`etharp_output()` 直接把 group 映射成 Ethernet multicast MAC

IGMP Report 本身就是 IPv4 multicast packet。IPv4 output 最终进入 Ethernet 时，`etharp_output()` 专门处理 multicast destination。[S1](#source-s1)[S3](#source-s3)

```c
} else if (ip4_addr_ismulticast(ipaddr)) {
  /* Hash IP multicast address to MAC address.*/
  mcastaddr.addr[0] = LL_IP4_MULTICAST_ADDR_0;
  mcastaddr.addr[1] = LL_IP4_MULTICAST_ADDR_1;
  mcastaddr.addr[2] = LL_IP4_MULTICAST_ADDR_2;
  mcastaddr.addr[3] = ip4_addr2(ipaddr) & 0x7f;
  mcastaddr.addr[4] = ip4_addr3(ipaddr);
  mcastaddr.addr[5] = ip4_addr4(ipaddr);
  dest = &mcastaddr;
```

前三个 byte 固定：

```text
01:00:5e
```

后 23 bit 来自 IPv4 multicast address 的低 23 bit。[S3](#source-s3)

因此 multicast output 不需要：

```text
IPv4 group
→ ARP Request
→ 等待 ARP Reply
```

而是可以直接：

```text
IPv4 multicast group
→ 01:00:5e:xx:xx:xx
→ ethernet_output()
```

## 17. 为什么多个 IPv4 multicast group 可能映射到同一个 Ethernet MAC

IPv4 multicast address 空间使用 28-bit group ID，而 Ethernet IPv4 multicast mapping 只携带其中低 23 bit。[S3](#source-s3)

因此这个映射不是一一对应：多个 IPv4 groups 会共享同一个 multicast MAC。

这也是为什么硬件 MAC filter 只能解决第一层粗过滤：

```text
Ethernet destination MAC
    ↓ 可能对应多个 IPv4 groups
ip4_input()
    ↓ 再检查真正 IPv4 destination group
IGMP membership
```

不能因为某帧 MAC 命中了 multicast filter，就直接认定它一定属于应用正在订阅的那个 IPv4 group。

## 18. `ip4_input()` 对 multicast packet 的接收条件：这个 `netif` 必须真的有 group entry

当 Ethernet frame 已经进入 lwIP，Stage 4 的 `ip4_input()` 会判断 destination 是否 multicast。[S1](#source-s1)

```c
if (ip4_addr_ismulticast(ip4_current_dest_addr())) {
#if LWIP_IGMP
  if ((inp->flags & NETIF_FLAG_IGMP) &&
      (igmp_lookfor_group(inp, ip4_current_dest_addr()))) {
    netif = inp;
  } else {
    netif = NULL;
  }
#endif /* LWIP_IGMP */
}
```

这一步把：

```text
“MAC 接收了这帧”
```

和：

```text
“lwIP 当前 interface 加入了这个 IPv4 multicast group”
```

明确分开。

如果 group 不存在，packet 不会因为 destination 是 multicast 就无条件交给 UDP/TCP。

## 19. IGMP control packet 怎样进入 `igmp_input()`

IPv4 Header 的 Protocol field 对 IGMP 使用 protocol number 2。`ip4_input()` 完成 Header 验证和 membership 接收判断后，protocol dispatch 进入：[S1](#source-s1)

```c
#if LWIP_IGMP
case IP_PROTO_IGMP:
  igmp_input(p, inp, ip4_current_dest_addr());
  break;
#endif /* LWIP_IGMP */
```

进入 `igmp_input()` 时：

```text
p->payload = IGMP Header
inp        = 收到 packet 的 netif
dest       = IPv4 destination group
```

这和 Stage 5 的 UDP input 一样，协议分发已经把上一层 Header 移开，当前函数只处理自己的 protocol header。

## 20. `igmp_input()` 先检查长度、checksum，再确认 group 是本机正在维护的 membership

进入 `igmp_input()`：[S1](#source-s1)

```c
if (p->len < IGMP_MINLEN) {
  pbuf_free(p);
  IGMP_STATS_INC(igmp.lenerr);
  return;
}

igmp = (struct igmp_msg *)p->payload;
if (inet_chksum(igmp, p->len)) {
  pbuf_free(p);
  IGMP_STATS_INC(igmp.chkerr);
  return;
}

group = igmp_lookfor_group(inp, dest);

if (!group) {
  pbuf_free(p);
  IGMP_STATS_INC(igmp.drop);
  return;
}
```

所以 IGMP packet 也不是看到 Type 就立刻改状态：必须先通过 packet validity 和 interface/group context 检查。

## 21. General Query：不是立即一起回答，而是每个 group 设置随机 delay timer

`igmp_input()` 遇到 `IGMP_MEMB_QUERY`，如果 destination 是 `224.0.0.1` 且 IGMP Group Address 字段为 0，就认作 General Query。[S1](#source-s1)[S4](#source-s4)

继续阅读该分支：

```c
groupref = netif_igmp_data(inp);

if (groupref != NULL) {
  groupref = groupref->next;
}

while (groupref) {
  igmp_delaying_member(groupref, igmp->igmp_maxresp);
  groupref = groupref->next;
}
```

第一项 all-systems group 被跳过，其余 memberships 分别进入 `igmp_delaying_member()`。

这样做的目的不是“故意变慢”，而是避免同一 LAN 上所有 hosts 同时发 Report。RFC 2236 规定 Host 对 Query 选择不超过 Max Response Time 的随机 delay；如果先听到别人的 Report，可以取消自己的重复 Report。[S4](#source-s4)

## 22. 进入 `igmp_delaying_member()`：只在需要时缩短 timer

`igmp_input()` 调用 `igmp_delaying_member()`。当前函数：[S1](#source-s1)

```c
static void
igmp_delaying_member(struct igmp_group *group, u8_t maxresp)
{
  if ((group->group_state == IGMP_GROUP_IDLE_MEMBER) ||
      ((group->group_state == IGMP_GROUP_DELAYING_MEMBER) &&
       ((group->timer == 0) || (maxresp < group->timer)))) {
    igmp_start_timer(group, maxresp);
    group->group_state = IGMP_GROUP_DELAYING_MEMBER;
  }
}
```

如果 group 已经在等待 Report，新 Query 给出的 Max Response Time 比当前剩余 timer 更短，才重新缩短倒计时；更长的 Query 不应该把一个本来更早的 response 推迟。

## 23. `igmp_start_timer()`：随机 delay 以 100 ms tick 表示

进入 `igmp_start_timer()`：[S1](#source-s1)

```c
static void
igmp_start_timer(struct igmp_group *group, u8_t max_time)
{
#ifdef LWIP_RAND
  group->timer = (u16_t)(max_time > 2 ? (LWIP_RAND() % max_time) : 1);
#else
  group->timer = max_time / 2;
#endif

  if (group->timer == 0) {
    group->timer = 1;
  }
}
```

当前 IGMP tick：

```c
#define IGMP_TMR_INTERVAL 100
```

也就是 timer 字段单位不是毫秒，而是 **100 ms tick 数量**。[S2](#source-s2)

如果 Port 提供 `LWIP_RAND`，当前实现会在允许范围内随机选择 report delay；没有随机源时退化成固定中间值，这属于实现 fallback，不应写成协议推荐行为。

## 24. `igmp_tmr()` 在哪里被注册：它是 lwIP cyclic timer，不是独立线程

Stage 11 已经解释 `sys_timeouts_init()`。IGMP timer 位于同一张 cyclic timer 表：[S2](#source-s2)

```c
#if LWIP_IGMP
{IGMP_TMR_INTERVAL, HANDLER(igmp_tmr)},
#endif /* LWIP_IGMP */
```

因此：

```text
sys_timeouts framework
    ↓ every 100 ms
igmp_tmr()
    ↓
扫描 netif group list
    ↓
group->timer--
    ↓ timer==0
igmp_timeout()
```

没有额外的“IGMP timer thread”。

## 25. Timer 到期：`igmp_timeout()` 发送真正的 Membership Report

进入 `igmp_tmr()`：[S1](#source-s1)

```c
while (group != NULL) {
  if (group->timer > 0) {
    group->timer--;
    if (group->timer == 0) {
      igmp_timeout(netif, group);
    }
  }
  group = group->next;
}
```

进入 `igmp_timeout()`：[S1](#source-s1)

```c
if ((group->group_state == IGMP_GROUP_DELAYING_MEMBER) &&
    (!(ip4_addr_eq(&(group->group_address), &allsystems)))) {
  group->group_state = IGMP_GROUP_IDLE_MEMBER;

  IGMP_STATS_INC(igmp.tx_report);
  igmp_send(netif, group, IGMP_V2_MEMB_REPORT);
}
```

状态变为 `IDLE_MEMBER`，再通过前面已经展开的 `igmp_send()` 发 Report。

## 26. Report Suppression：听到别的 Host 已经报告，就取消自己的 timer

这是 IGMP 最值得理解的协作机制之一。

当本机仍处于 `DELAYING_MEMBER`，但先收到同 group 的 `IGMP_V2_MEMB_REPORT`，`igmp_input()` 执行：[S1](#source-s1)[S4](#source-s4)

```c
case IGMP_V2_MEMB_REPORT:
  IGMP_STATS_INC(igmp.rx_report);
  if (group->group_state == IGMP_GROUP_DELAYING_MEMBER) {
    group->timer = 0;
    group->group_state = IGMP_GROUP_IDLE_MEMBER;
    group->last_reporter_flag = 0;
  }
  break;
```

于是多个 Hosts 同时属于一个 group 时，Query 后通常不需要每台机器都发 Report。

```mermaid
sequenceDiagram
    participant R as Multicast Router
    participant A as Host A
    participant B as Host B

    R->>A: General Query
    R->>B: General Query
    A->>A: random timer = short
    B->>B: random timer = long
    A->>R: Membership Report
    A->>B: multicast Report visible on LAN
    B->>B: stop timer / suppress duplicate report
```

这也是 `last_reporter_flag` 会被清零的原因：Host B 已经知道自己不是最后一个 report 的成员。

## 27. 三态状态机：Non-Member、Delaying Member、Idle Member

当前 lwIP 定义：[S1](#source-s1)[S4](#source-s4)

```c
#define IGMP_GROUP_NON_MEMBER          0
#define IGMP_GROUP_DELAYING_MEMBER     1
#define IGMP_GROUP_IDLE_MEMBER         2
```

主路径：

```mermaid
stateDiagram-v2
    [*] --> NON_MEMBER
    NON_MEMBER --> DELAYING_MEMBER: join / send immediate Report / start timer
    DELAYING_MEMBER --> IDLE_MEMBER: timer expires / send Report
    DELAYING_MEMBER --> IDLE_MEMBER: other Report received / suppress own Report
    IDLE_MEMBER --> DELAYING_MEMBER: Query received / start timer
    DELAYING_MEMBER --> [*]: final leave
    IDLE_MEMBER --> [*]: final leave
```

`NON_MEMBER` 主要是新创建 group object 的初始状态；最终 leave 时当前实现会把 group 从 list 删除并 `memp_free()`，而不是保留一个永久 Non-Member object。

## 28. `use` 不是网络上的成员数量，而是本机对同一 group 的引用计数

同一个 `netif` 上多个 Socket/模块可能都请求加入同一 group。`igmp_lookup_group()` 会找到同一个 `struct igmp_group`，`igmp_joingroup_netif()` 最后执行：

```c
group->use++;
```

所以：

```text
use = 3
```

表示本机三个逻辑使用者共享这条 membership，并不表示 LAN 上有三个 Hosts。

这也是为什么一次 `IP_DROP_MEMBERSHIP` 不一定立刻发送 Leave。

## 29. Leave：只有本机最后一个使用者离开时才真正拆 membership

从 Socket `IP_DROP_MEMBERSHIP` 返回到 IGMP Core 后，最终进入 `igmp_leavegroup_netif()`。[S1](#source-s1)

```c
if (group->use <= 1) {
  igmp_remove_group(netif, group);

  if (group->last_reporter_flag) {
    IGMP_STATS_INC(igmp.tx_leave);
    igmp_send(netif, group, IGMP_LEAVE_GROUP);
  }

  if (netif->igmp_mac_filter != NULL) {
    netif->igmp_mac_filter(netif, groupaddr, NETIF_DEL_MAC_FILTER);
  }

  memp_free(MEMP_IGMP_GROUP, group);
} else {
  group->use--;
}
```

这里形成完整 cleanup：

```text
最后一个 local user 离开
    ↓
从 netif group list 删除
    ↓
如果 last reporter → 发送 Leave Group
    ↓
可选 MAC filter DEL
    ↓
释放 MEMP_IGMP_GROUP
```

如果 `use > 1`，只减少本机引用，网络 membership 仍保持。

## 30. 为什么只有 `last_reporter_flag=1` 才需要发 Leave

RFC 2236 的优化语义是：如果本机不是最后一个发送 Report 的 Host，那么已经观察到链路上还有其他 group member；离开时可以不发送 Leave，减少不必要 control traffic。[S4](#source-s4)

当前 lwIP 通过：

```text
自己发送 Report       -> last_reporter_flag = 1
听到别人的同组 Report -> last_reporter_flag = 0
```

保存这个事实。

所以 `last_reporter_flag` 不是“是不是最后一个真实成员”的绝对真相，而是 Host 根据最近 Report 观察得到的协议状态。

## 31. Current lwIP `igmp.c` 的实现边界：主线是 IGMPv2，不是 IGMPv3 source filtering

当前 `igmp_input()` 处理：

- Membership Query；
- IGMPv2 Membership Report；
- Leave 由本机发送；
- `igmp_maxresp==0` 的 v1-style Query 被按兼容路径处理。[S1](#source-s1)

源码没有 IGMPv3 INCLUDE/EXCLUDE source list state machine。因此当前 `igmp_joingroup*()` 表达的是传统 group membership：

```text
(*, G)
```

而不是：

```text
(S, G) source-specific membership
```

upstream RTP example 虽然默认 group 位于 `232.0.0.0`，但本篇只用它作为现成的 `IP_ADD_MEMBERSHIP` call site；不把这个 example 的地址选择泛化成当前 lwIP 已实现完整 IGMPv3/SSM semantics。

## 32. Unix TAP 与 MCU Ethernet MAC：同一 IGMP Core，MAC filter 边界不同

当前 Unix TAP Port：

```text
NETIF_FLAG_IGMP = yes
igmp_mac_filter callback = not installed
```

因此 Core 仍然会：

```text
维护 group list
发送 Membership Report
处理 Query
执行 timer / suppression / leave
```

但不会通过 callback 编程真实 Ethernet multicast filter。

典型 MCU Port 则可能：

```text
igmp_joingroup_netif()
    ↓
netif->igmp_mac_filter(ADD)
    ↓
Driver
    ↓
MAC hash/perfect filter
```

这正好连接 Stage 0 的 MAC receive filter：**协议栈 membership 和硬件 receive filter 属于不同层，但 Port 必须把两层协调起来。**

## 33. Host 实验：启用 upstream RTP app，最直接观察 join 产生的 IGMP Report

当前 `example_app/lwipcfg.h` 默认：

```c
#define LWIP_RTP_APP                  0
```

若要观察本文真实入口，可以在完成当前 configure 后，把当前实验配置改为：

```c
#define LWIP_RTP_APP                  1
```

然后按仓库已有 build 流程重新构建。本文没有执行 build；命令是否成功以本地实际环境为准。

启动 example 前先抓 IGMP：

```sh
sudo tcpdump -i lwip0 -nn -vv igmp
```

如果 `rtp_recv_thread()` 成功运行到前文已经展示过的 membership call site：

```c
lwip_setsockopt(sock, IPPROTO_IP, IP_ADD_MEMBERSHIP, ...)
```

预期最先看到的网络证据就是发往 RTP group 的 IGMPv2 Membership Report；随后短 delay timer 还可能再次产生 Report。[S1](#source-s1)

保存 PCAP：

```sh
mkdir -p captures
sudo tcpdump -i lwip0 -nn -s 0 -U -w captures/stage17-igmp.pcap igmp
```

实际 packet 数量、时序和 Host 网络环境相关；本文没有运行该实验，因此不把固定帧数写成已确认事实。

## 34. PCAP 应怎样和源码逐字段对应

抓到 Membership Report 后，至少建立以下映射：

| PCAP 字段 | lwIP 对应 |
| --- | --- |
| IPv4 Protocol = 2 | `IP_PROTO_IGMP` → `igmp_input()` |
| IPv4 TTL = 1 | `IGMP_TTL` |
| Router Alert option | `igmp_ip_output_if()` 的 `ra[]` |
| IGMP Type = `0x16` | `IGMP_V2_MEMB_REPORT` |
| Group Address | `group->group_address` |
| IGMP checksum | `inet_chksum()` |
| Destination IPv4 = group | `igmp_send()` 的 `dest` |
| Destination MAC `01:00:5e:*` | `etharp_output()` multicast mapping |

这比只看到“有一个 IGMP packet”更重要：报文中的每个关键字段都应该能回到具体结构体、宏和发送函数。

## 35. 最终回看：从一个 Socket join 到链路上的 multicast membership

```mermaid
flowchart TD
    A["rtp_recv_thread()"] --> B["lwip_setsockopt(IP_ADD_MEMBERSHIP)"]
    B --> C["tcpip_callback / Core Lock"]
    C --> D["lwip_setsockopt_impl()"]
    D --> E["igmp_joingroup()"]
    E --> F["igmp_joingroup_netif()"]
    F --> G["MEMP_IGMP_GROUP / group state"]
    F --> H["optional igmp_mac_filter(ADD)"]
    F --> I["igmp_send(Membership Report)"]
    I --> J["ip4_output_if_opt()"]
    J --> K["etharp_output(): 01:00:5e mapping"]
```

运行过程中：

```mermaid
flowchart TD
    A["Router General/Group Query"] --> B["ip4_input()"]
    B --> C["igmp_input()"]
    C --> D["igmp_delaying_member()"]
    D --> E["random report timer"]
    E --> F{"先听到别人的 Report?"}
    F -->|是| G["cancel own timer / IDLE_MEMBER"]
    F -->|否，timer 到期| H["igmp_timeout()"]
    H --> I["send Membership Report"]
```

离开时：

```text
IP_DROP_MEMBERSHIP
    ↓
igmp_leavegroup_netif()
    ↓
local use count
    ↓
最后一个使用者？
    ├─ 否 → use--
    └─ 是 → optional Leave + MAC filter DEL + memp_free
```

到这里，IPv4 multicast 的三个层次已经可以分开理解：

1. **应用/Socket**：是否订阅 group，以及 UDP port；
2. **IGMP/IP**：本 interface 是否属于 group、何时 Report/Leave；
3. **Ethernet/Driver**：IPv4 group 映射到哪个 multicast MAC，硬件是否放行该 MAC。

下一阶段如果继续沿 multicast 展开，最自然的是 IPv6 MLD：它与 IGMP 的目标相似，但控制消息属于 ICMPv6，group 地址与 Ethernet `33:33:*` 映射、状态和消息格式都不同。

## 资料来源

<a id="source-s1"></a>
### [S1] lwIP IGMP、Socket、IPv4/Ethernet 与 Unix TAP 实现
- 类型：目标版本 upstream 源码；版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- 定位：`src/core/ipv4/igmp.c`、`src/core/ipv4/ip4.c`、`src/core/ipv4/etharp.c`、`src/core/netif.c`、`src/api/sockets.c`、`contrib/apps/rtp/rtp.c`、`contrib/ports/unix/port/netif/tapif.c`
- URL/文档：[lwIP upstream @ d08f477](https://github.com/lwip-tcpip/lwip/tree/d08f4773edd0182b7910fc8f046eed82ffcd67c9)
- 使用位置：RTP Socket join、线程桥接、IGMP init/join/query/report/leave、IPv4 multicast receive 与 Ethernet mapping
- 支撑内容：当前 revision 的真实应用入口、Core 调用链、group state、MAC filter callback 边界与 multicast output

<a id="source-s2"></a>
### [S2] lwIP IGMP 配置、memp 与 timer
- 类型：目标版本 upstream 源码；版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- 定位：`src/include/lwip/opt.h`、`src/include/lwip/igmp.h`、`src/include/lwip/prot/igmp.h`、`src/include/lwip/priv/memp_std.h`、`src/core/timeouts.c`
- URL/文档：[lwIP IGMP headers](https://github.com/lwip-tcpip/lwip/tree/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip)
- 使用位置：`LWIP_IGMP`、`MEMP_NUM_IGMP_GROUP`、三态定义、100 ms cyclic timer
- 支撑内容：编译开关、group pool、timer interval 与 message/state 常量

<a id="source-s3"></a>
### [S3] RFC 1112 — Host Extensions for IP Multicasting
- 类型：IETF / RFC Editor；版本：RFC 1112，1989-08
- URL/文档：[RFC 1112](https://www.rfc-editor.org/rfc/rfc1112.html)
- 使用位置：IPv4 multicast host model、Ethernet `01:00:5e` 低 23-bit mapping、all-systems group 背景
- 支撑内容：IPv4 multicast host extension 与 Ethernet multicast address mapping

<a id="source-s4"></a>
### [S4] RFC 2236 — Internet Group Management Protocol, Version 2
- 类型：IETF / RFC Editor；版本：RFC 2236，1997-11
- URL/文档：[RFC 2236](https://www.rfc-editor.org/rfc/rfc2236.html)
- 使用位置：Query/Report/Leave、Max Response Time、Report suppression、last reporter、三态 host state machine
- 支撑内容：IGMPv2 host membership protocol、message destination 与 timer/state 语义
