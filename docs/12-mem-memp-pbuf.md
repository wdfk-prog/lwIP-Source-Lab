<meta name="referrer" content="no-referrer" />

# 教程 12：从 `pbuf_alloc()` / `tcp_new()` 到资源回收——`mem`、`memp` 与 `pbuf` 内存体系

> 摘要：把 pbuf、UDP/TCP PCB、TCP segment、Netconn 与 tcpip message 放回统一资源模型，理解 variable heap、typed pools 与 packet-buffer policy。

[TOC]

本文源码块采用统一约定：除非代码块前明确标注为“上游连续源码片段”，其余 C 代码块一律视为按当前 revision 裁剪的“执行路径阅读版”。阅读版只删除与当前主线无关的注释、条件编译或旁支，不重排保留语句，也不使用省略号伪装缺失源码；示意代码会另行标注。

前面的文章已经遇到很多“分配失败”入口：

```text
pbuf_alloc(PBUF_RAM / PBUF_POOL)
udp_new()
tcp_new()/tcp_alloc()
tcp_listen()
netconn_new()
tcpip_inpkt()
```

如果把它们都理解成“heap malloc”，会直接误判资源瓶颈。当前 lwIP 把内存管理拆成三个互相关联、但语义不同的层次：`mem`、`memp` 与 `pbuf`。[S1](#source-s1)[S2](#source-s2)[S3](#source-s3)

## 1. 先从三个已经见过的真实 allocation call 对比

`tapif.c::low_level_input()` 在 Stage 2 RX 路径中调用：[S3](#source-s3)

```c
pbuf_alloc(PBUF_RAW, len, PBUF_POOL);
```

`udp_new_ip_type()` 在 Stage 5 创建 UDP PCB 时调用：[S4](#source-s4)

```c
memp_malloc(MEMP_UDP_PCB);
```

`tcp_alloc()` 在 Stage 7 创建 TCP connection PCB 时调用：[S5](#source-s5)

```c
memp_malloc(MEMP_TCP_PCB);
```

而 `tcp_write()` 产生的数据 pbuf 在一些路径上又会使用 `PBUF_RAM`，最终进入 `mem_malloc()`。[S3](#source-s3)

所以“lwIP 内存”不是一个池子：

```mermaid
flowchart TD
    A["lwIP allocation request"] --> B{"对象是什么？"}
    B -->|"variable-size memory"| C["mem / mem_malloc()"]
    B -->|"typed fixed object"| D["memp / MEMP_* pool"]
    B -->|"packet buffer"| E["pbuf API"]
    E -->|"PBUF_RAM"| C
    E -->|"PBUF_POOL"| F["MEMP_PBUF_POOL"]
    E -->|"PBUF_REF / PBUF_ROM metadata"| G["MEMP_PBUF"]
```

## 2. `mem`：变量大小 allocation，真实代码怎样找 free block

`mem` 提供 `mem_malloc()` / `mem_free()` 等 variable-size allocator API。[S1](#source-s1) 当前 example 的 `MEM_ALIGNMENT=4`、`MEM_SIZE=10240` 只是这套 Host 配置给 internal heap 的预算，不是 lwIP 固定要求。[S6](#source-s6)

先看默认 internal allocator 的 `mem_malloc()`。函数先把请求长度按 `MEM_ALIGNMENT` 对齐，再从 `lfree` 指向的最低 free block 开始扫描：[S1](#source-s1)

```c
void *
mem_malloc(mem_size_t size_in)
{
  mem_size_t ptr, ptr2, size;
  struct mem *mem, *mem2;
  LWIP_MEM_ALLOC_DECL_PROTECT();

  if (size_in == 0) {
    return NULL;
  }

  size = (mem_size_t)LWIP_MEM_ALIGN_SIZE(size_in);
  if (size < MIN_SIZE_ALIGNED) {
    size = MIN_SIZE_ALIGNED;
  }
  if ((size > MEM_SIZE_ALIGNED) || (size < size_in)) {
    return NULL;
  }

  sys_mutex_lock(&mem_mutex);
  LWIP_MEM_ALLOC_PROTECT();

  for (ptr = mem_to_ptr(lfree); ptr < MEM_SIZE_ALIGNED - size;
       ptr = ptr_to_mem(ptr)->next) {
    mem = ptr_to_mem(ptr);

    if ((!mem->used) &&
        (mem->next - (ptr + SIZEOF_STRUCT_MEM)) >= size) {
```

继续阅读 `mem_malloc()`。找到足够大的 free block 后，如果剩余空间还能容纳新的 `struct mem` 和最小数据区，`mem_malloc()` 会把当前 block 拆成“本次已用块 + 新 free remainder”：[S1](#source-s1)

```c
if (mem->next - (ptr + SIZEOF_STRUCT_MEM) >=
    (size + SIZEOF_STRUCT_MEM + MIN_SIZE_ALIGNED)) {
  ptr2 = (mem_size_t)(ptr + SIZEOF_STRUCT_MEM + size);
  LWIP_ASSERT("invalid next ptr", ptr2 != MEM_SIZE_ALIGNED);

  mem2 = ptr_to_mem(ptr2);
  mem2->used = 0;
  mem2->next = mem->next;
  mem2->prev = ptr;

  mem->next = ptr2;
  mem->used = 1;

  if (mem2->next != MEM_SIZE_ALIGNED) {
    ptr_to_mem(mem2->next)->prev = ptr2;
  }
  MEM_STATS_INC_USED(used, (size + SIZEOF_STRUCT_MEM));
} else {
  mem->used = 1;
  MEM_STATS_INC_USED(used, mem->next - mem_to_ptr(mem));
}
```

因此 `mem_malloc()` 不是“从一个固定-size object pool 弹一个节点”，它需要处理长度、对齐、free-block 搜索和必要的 block split。这也是 `mem` 与下一节 `memp` 的本质差异。

`PBUF_RAM` 是前文最直接的使用者：`pbuf_alloc()` 根据 packet 长度算出 metadata + headroom + payload 的总大小，然后一次 `mem_malloc(alloc_len)`。[S3](#source-s3)

## 3. `memp`：按对象类型分开的 fixed-size pools

`memp` 面向的是“对象类型已知、element 大小固定、数量可配置”的资源。[S2](#source-s2) `memp_malloc(type)` 先用 `type` 找到对应 pool descriptor，再进入该 pool 的 free-list 操作：[S2](#source-s2)

```c
void *
memp_malloc(memp_t type)
{
  void *memp;
  LWIP_ERROR("memp_malloc: type < MEMP_MAX", (type < MEMP_MAX), return NULL;);

#if MEMP_OVERFLOW_CHECK >= 2
  memp_overflow_check_all();
#endif /* MEMP_OVERFLOW_CHECK >= 2 */

  memp = do_memp_malloc_pool(memp_pools[type]);

  return memp;
}
```

`memp_malloc()` 调用 `do_memp_malloc_pool()` 后，控制流进入具体 pool。默认 `MEMP_MEM_MALLOC=0` 时，下面继续阅读 `do_memp_malloc_pool()`：真正取 element 的位置是 `*desc->tab`，也就是当前 pool free list 的表头。[S2](#source-s2)

```c
SYS_ARCH_PROTECT(old_level);

memp = *desc->tab;

if (memp != NULL) {
  *desc->tab = memp->next;

#if MEMP_STATS
  desc->stats->used++;
  if (desc->stats->used > desc->stats->max) {
    desc->stats->max = desc->stats->used;
  }
#endif
  SYS_ARCH_UNPROTECT(old_level);
  return ((u8_t *)memp + MEMP_SIZE);
} else {
#if MEMP_STATS
  desc->stats->err++;
#endif
  SYS_ARCH_UNPROTECT(old_level);
}

return NULL;
```

这段代码说明 fixed pool allocation 的关键行为非常直接：

```text
pool free-list head
      ↓ pop
返回一个固定大小 element
```

pool 空了就返回 `NULL`，`memp_malloc()` 自己不会去借另一个类型的 pool，也不会自动扩容。某些上层模块会在失败后自行执行 reclaim policy，`tcp_alloc()` 就是后面的典型例子。

`memp_std.h` 把对象类型映射到各自 pool，例如 `MEMP_TCP_PCB`、`MEMP_TCP_SEG`、`MEMP_NETCONN`、`MEMP_TCPIP_MSG_INPKT`。因此“TCP PCB pool 用完”与“UDP PCB pool 用完”是两个独立资源状态。

## 4. 当前 example 的 resource budget 是怎样拆开的

当前 `lwipopts.h` 给出：[S6](#source-s6)

| 资源 | 当前数量/大小 | 前面在哪见过 |
| --- | ---: | --- |
| `MEM_SIZE` | 10240 bytes | `PBUF_RAM` 等 variable allocation |
| `MEMP_NUM_PBUF` | 16 | `PBUF_REF/PBUF_ROM` metadata |
| `MEMP_NUM_UDP_PCB` | 8 | Stage 5 `udp_new()` |
| `MEMP_NUM_TCP_PCB` | 5 | Stage 7 active TCP PCB |
| `MEMP_NUM_TCP_PCB_LISTEN` | 8 | Stage 7 listener |
| `MEMP_NUM_TCP_SEG` | 16 | Stage 8 TX queue / Stage 10 ooseq metadata |
| `MEMP_NUM_NETBUF` | 2 | Stage 6 Netconn payload wrapper |
| `MEMP_NUM_NETCONN` | 12 | Stage 6 sequential connection object |
| `MEMP_NUM_TCPIP_MSG_API` | 16 | API/callback work item |
| `MEMP_NUM_TCPIP_MSG_INPKT` | 16 | Stage 11 RX mailbox handoff |
| `PBUF_POOL_SIZE` | 120 | packet pool elements |
| `PBUF_POOL_BUFSIZE` | 256 bytes | 每个 packet pool element 的 buffer 尺寸 |

这张表最重要的不是记数字，而是说明 resource budgeting 要按对象类型做。比如高并发 TCP connection 可能先碰 `MEMP_TCP_PCB`；高吞吐 RX burst 可能先压 `PBUF_POOL`；大量 pending TX segments 又可能先消耗 `MEMP_TCP_SEG`。

## 5. `pbuf` 为什么横跨 `mem` 和 `memp`

`pbuf` 是 packet-buffer abstraction，本身并不是第三套底层 heap。`pbuf_alloc(layer, length, type)` 内部的 `switch(type)` 明确把不同 pbuf policy 路由到不同 allocator。[S3](#source-s3)

### 5.1 `PBUF_POOL`：循环从 `MEMP_PBUF_POOL` 取 element

当前源码不是只调用一次 `memp_malloc()`，而是按剩余长度循环构造 pbuf chain：[S3](#source-s3)

```c
case PBUF_POOL: {
  struct pbuf *q, *last;
  u16_t rem_len;
  p = NULL;
  last = NULL;
  rem_len = length;
  do {
    u16_t qlen;
    q = (struct pbuf *)memp_malloc(MEMP_PBUF_POOL);
    if (q == NULL) {
      PBUF_POOL_IS_EMPTY();
      if (p) {
        pbuf_free(p);
      }
      return NULL;
    }
    qlen = LWIP_MIN(rem_len,
                    (u16_t)(PBUF_POOL_BUFSIZE_ALIGNED - LWIP_MEM_ALIGN_SIZE(offset)));
    pbuf_init_alloced_pbuf(q,
                           LWIP_MEM_ALIGN((void *)((u8_t *)q + SIZEOF_STRUCT_PBUF + offset)),
                           rem_len, qlen, type, 0);
    if (p == NULL) {
      p = q;
    } else {
      last->next = q;
    }
    last = q;
    rem_len = (u16_t)(rem_len - qlen);
    offset = 0;
  } while (rem_len > 0);
  break;
}
```

如果中途某个 pool element 分配失败，当前已经建立的 chain 会先 `pbuf_free(p)` 回滚，而不是把半条 packet chain 留给调用者。这也是为什么一个大 frame 可能因为 pool 中“剩余 element 个数不足”而整体 allocation 失败。

### 5.2 `PBUF_RAM`：一次 variable-size `mem_malloc()`

`PBUF_RAM` 走的是另一条路径：[S3](#source-s3)

```c
case PBUF_RAM: {
  mem_size_t payload_len =
      (mem_size_t)(LWIP_MEM_ALIGN_SIZE(offset) + LWIP_MEM_ALIGN_SIZE(length));
  mem_size_t alloc_len =
      (mem_size_t)(LWIP_MEM_ALIGN_SIZE(SIZEOF_STRUCT_PBUF) + payload_len);

  if ((payload_len < LWIP_MEM_ALIGN_SIZE(length)) ||
      (alloc_len < LWIP_MEM_ALIGN_SIZE(length))) {
    return NULL;
  }

  p = (struct pbuf *)mem_malloc(alloc_len);
  if (p == NULL) {
    return NULL;
  }
  pbuf_init_alloced_pbuf(p,
                         LWIP_MEM_ALIGN((void *)((u8_t *)p + SIZEOF_STRUCT_PBUF + offset)),
                         length, length, type, 0);
  break;
}
```

所以 `PBUF_RAM` 消耗的是 variable heap；metadata、headroom 和 payload backing memory 位于同一次 allocation 中。

### 5.3 `PBUF_REF` / `PBUF_ROM`：只分配 metadata

这两类 payload 由外部 owner 提供，`pbuf_alloc_reference()` 只从 `MEMP_PBUF` 获取 `struct pbuf` metadata：[S3](#source-s3)

```c
p = (struct pbuf *)memp_malloc(MEMP_PBUF);
if (p == NULL) {
  return NULL;
}
pbuf_init_alloced_pbuf(p, payload, length, length, type, 0);
```

因此“REF/ROM 是 zero-copy”不能理解成“完全不占 lwIP resource”。payload 可以不复制，但 metadata 仍消耗 `MEMP_PBUF`；如果外部 buffer lifetime 不足以覆盖异步排队时间，还必须通过 `pbuf_take()` 等方式转成自有数据。

## 6. `PBUF_POOL_SIZE` 与 `MEMP_NUM_PBUF` 不是同一个池

名称很相似，必须在这里消歧：[S2](#source-s2)[S3](#source-s3)

```text
PBUF_POOL_SIZE
    -> MEMP_PBUF_POOL element 数量
    -> element 同时包含 struct pbuf + pool payload backing memory

MEMP_NUM_PBUF
    -> MEMP_PBUF element 数量
    -> 主要用于只需要 pbuf metadata 的 REF/ROM 等场景
```

因此把 `MEMP_NUM_PBUF=16` 误认为“整个系统最多只能有 16 个 pbuf”是错误的；RX 的 `PBUF_POOL` 有自己独立的 `PBUF_POOL_SIZE=120`。

## 7. UDP/TCP PCB 为什么更适合 typed pool

`udp_new()` 直接从 `MEMP_UDP_PCB` 分配 `struct udp_pcb`。[S4](#source-s4)

TCP 普通 PCB、listen PCB 也分别来自：

```text
MEMP_TCP_PCB
MEMP_TCP_PCB_LISTEN
```

Stage 7 已经看到 `tcp_listen()` 为什么把普通 PCB 换成更小的 listener object；内存体系现在给出另一个视角：两种对象不仅 struct 不同，而且来自不同 typed pools。[S5](#source-s5)

这种设计让资源上限更显式，也避免把所有控制对象都交给 variable-size heap 管理。

## 8. `tcp_alloc()` 为什么不是第一次 pool allocation 失败就返回 NULL

`memp_malloc()` 本身 pool 空即返回 `NULL`，但 TCP 在它上面增加了一层协议专用的资源回收策略。直接看 `tcp_alloc()`：[S5](#source-s5)

```c
pcb = (struct tcp_pcb *)memp_malloc(MEMP_TCP_PCB);
if (pcb == NULL) {
  tcp_handle_closepend();

  tcp_kill_timewait();
  pcb = (struct tcp_pcb *)memp_malloc(MEMP_TCP_PCB);
  if (pcb == NULL) {
    tcp_kill_state(LAST_ACK);
    pcb = (struct tcp_pcb *)memp_malloc(MEMP_TCP_PCB);
    if (pcb == NULL) {
      tcp_kill_state(CLOSING);
      pcb = (struct tcp_pcb *)memp_malloc(MEMP_TCP_PCB);
      if (pcb == NULL) {
        tcp_kill_prio(prio);
        pcb = (struct tcp_pcb *)memp_malloc(MEMP_TCP_PCB);
        if (pcb != NULL) {
          MEMP_STATS_DEC(err, MEMP_TCP_PCB);
        }
      }
      if (pcb != NULL) {
        MEMP_STATS_DEC(err, MEMP_TCP_PCB);
      }
    }
    if (pcb != NULL) {
      MEMP_STATS_DEC(err, MEMP_TCP_PCB);
    }
  }
  if (pcb != NULL) {
    MEMP_STATS_DEC(err, MEMP_TCP_PCB);
  }
}
```

这段调用链非常适合区分“allocator policy”和“protocol policy”：

```text
memp_malloc(MEMP_TCP_PCB)
    pool empty -> NULL

TCP tcp_alloc()
    ↓
处理 pending close
    ↓
回收 TIME_WAIT
    ↓ retry
回收 LAST_ACK
    ↓ retry
回收 CLOSING
    ↓ retry
回收更低 priority active PCB
    ↓ retry
最终仍失败才返回 NULL
```

成功拿到 PCB 后，`tcp_alloc()` 才清零结构并初始化发送窗口、接收窗口、MSS、RTO、timer、`ssthresh` 等协议状态：[S5](#source-s5)

```c
if (pcb != NULL) {
  memset(pcb, 0, sizeof(struct tcp_pcb));
  pcb->prio = prio;
  pcb->snd_buf = TCP_SND_BUF;
  pcb->rcv_wnd = pcb->rcv_ann_wnd = TCPWND_MIN16(TCP_WND);
  pcb->ttl = TCP_TTL;
  pcb->mss = INITIAL_MSS;
  pcb->rto = LWIP_TCP_RTO_TIME / TCP_SLOW_INTERVAL;
  pcb->sv = LWIP_TCP_RTO_TIME / TCP_SLOW_INTERVAL;
  pcb->rtime = -1;
  pcb->cwnd = 1;
  pcb->tmr = tcp_ticks;
  pcb->last_timer = tcp_timer_ctr;
  pcb->ssthresh = TCP_SND_BUF;
}
```

所以 `tcp_new()` 返回的并不是“一块刚 malloc 出来的裸内存”，而是已经建立基本 TCP invariant 的 PCB。

这个 reclaim 策略只属于当前 TCP implementation。UDP 的 `udp_new()` 不会因为 `MEMP_UDP_PCB` 耗尽而自动杀 TIME_WAIT TCP connection；不同协议对象的资源策略不能从 `memp_malloc()` 名字推断为相同。

## 9. TCP segment 也有自己的 pool

Stage 8 `tcp_write()` 构造 queue node、Stage 10 `ooseq` 保存 segment metadata 时都会使用 `struct tcp_seg`。它由 `MEMP_TCP_SEG` 管理。[S2](#source-s2)[S5](#source-s5)

发送侧的真实分配点在 `tcp_create_segment()`。它先为 segment metadata 申请 `MEMP_TCP_SEG`，失败时会释放已经传入的 pbuf，再返回 `NULL`：[S5](#source-s5)

```c
if ((seg = (struct tcp_seg *)memp_malloc(MEMP_TCP_SEG)) == NULL) {
  LWIP_DEBUGF(TCP_OUTPUT_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
              ("tcp_create_segment: no memory.\n"));
  pbuf_free(p);
  return NULL;
}
seg->flags = optflags;
seg->next = NULL;
seg->p = p;
LWIP_ASSERT("p->tot_len >= optlen", p->tot_len >= optlen);
seg->len = p->tot_len - optlen;
```

接收侧乱序队列并不会复制 payload；`tcp_seg_copy()` 再取一个 `MEMP_TCP_SEG` 节点，复制 metadata，并通过 `pbuf_ref()` 增加底层 pbuf 引用计数：[S5](#source-s5)

```c
cseg = (struct tcp_seg *)memp_malloc(MEMP_TCP_SEG);
if (cseg == NULL) {
  return NULL;
}
SMEMCPY((u8_t *)cseg, (const u8_t *)seg, sizeof(struct tcp_seg));
pbuf_ref(cseg->p);
return cseg;
```

因此 `MEMP_TCP_SEG` 同时支撑发送队列和接收端 `ooseq` 的 segment metadata。高吞吐、较大发送窗口或大量乱序场景都可能提高这个 pool 的占用，而 payload backing memory 则还会另外消耗 pbuf/mem 资源。

因此一个 TCP connection 即使 PCB allocation 成功，后续也可能因为 segment pool 紧张而不能继续正常 enqueue。

这说明 TCP resource sizing 至少有两个独立维度：

```text
connection count
    -> MEMP_TCP_PCB

queued segment count
    -> MEMP_TCP_SEG
```

还没算 payload backing memory、pbuf pool 和 API message objects。

## 10. 一次 TCP Echo 会同时跨多个 allocator

把 Stage 7～11 的对象放回来，可以看到一次很普通的 Echo 已经涉及多个资源域：

```mermaid
flowchart TD
    A["TCP connection accepted"] --> B["MEMP_TCP_PCB"]
    A --> C["example state via mem_malloc()"]
    D["TAP RX frame"] --> E["PBUF_POOL / MEMP_PBUF_POOL"]
    E --> F["tcpip message\nMEMP_TCPIP_MSG_INPKT"]
    F --> G["TCP RX"]
    G --> H["tcp_write() TX"]
    H --> I["MEMP_TCP_SEG"]
    H --> J["TX pbuf backing memory\nmem or pbuf policy"]
    I --> K["ACK 后释放 segment"]
    J --> L["发送/确认完成后释放 pbuf"]
```

所以排查“为什么 tcp_write 返回 `ERR_MEM`”时，不能只看系统总剩余 RAM。具体失败可能来自 queue limit、segment pool、pbuf allocation 或其他 TCP accounting 条件。[S5](#source-s5)

## 11. `lwip_stats` 提供的是按 allocator/domain 观察资源的反馈面

lwIP 的 stats 配置可以记录 `mem`、`memp`、protocol 等统计；pool stats 能区分不同 `MEMP_*` 类型的 used/max/err 等信息。[S7](#source-s7)

这个反馈面对应前面建立的资源模型：

```text
不是只问：还剩多少 RAM？

而是问：
- 哪个 typed pool 接近上限？
- heap allocation 是否失败？
- PBUF_POOL 是否出现 empty？
- TCP segment/PCB/msg 哪类对象增长？
```

这种分类比盲目增大 `MEM_SIZE` 更接近真正的 sizing 问题。

## 12. 三个配置可以改变 allocator 模型

最后再看三个会改变底层实现的选项，因为到这里已经知道默认路径是什么。[S8](#source-s8)

### 12.1 `MEM_LIBC_MALLOC`

打开后，`mem` 改用 C library 的 `malloc/free/calloc`，而不是 lwIP internal heap。

这改变的是 `mem` backend，不意味着所有 `memp` pool 自动消失。

### 12.2 `MEM_CUSTOM_ALLOCATOR`

允许项目提供自定义 `MEM_CUSTOM_MALLOC/FREE/CALLOC`。`MEM_LIBC_MALLOC` 可以看作这个机制的一种特殊配置。

### 12.3 `MEMP_MEM_MALLOC`

这个选项影响更大：让 `memp` objects 改用 `mem_malloc/mem_free`，而不是 fixed pool allocator。upstream 注释特别提醒，这会改变执行速度以及 interrupt-context allocation 的工程约束。[S8](#source-s8)

所以它不是“省一点静态池空间”的无代价开关。打开后，前面“typed fixed pool 数量就是硬上限”的默认心智模型也会改变。

## 13. 到 Stage 12 为止形成的统一数据面模型

```text
Host Ethernet frame
  -> TAP / netif
  -> PBUF_POOL
  -> tcpip message + tcpip_thread
  -> Ethernet / ARP / IPv4
  -> UDP PCB 或 TCP PCB
  -> TCP segment queues / ooseq / retransmission
  -> Raw / Netconn / Socket application API
```

这条链上每个“对象”都同时有两种视角：

1. 协议/线程职责：它做什么；
2. resource ownership：它从哪里分配、谁持有、什么时候释放。

Stage 3 先解决 pbuf lifetime，Stage 12 再把 PCB、segment、message 与 pbuf 放进完整 allocator 体系，两篇因此不是重复关系。

## 资料来源

<a id="source-s1"></a>
### [S1] lwIP `mem` allocator
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/mem.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/mem.c)、[`src/include/lwip/mem.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/mem.h)
- 使用位置：variable-size heap、`mem_malloc()`/`mem_free()`
- 支撑内容：默认 lwIP heap abstraction 与 allocation API

<a id="source-s2"></a>
### [S2] lwIP typed memory pools
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/memp.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/memp.c)、[`src/include/lwip/memp.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/memp.h)、[`src/include/lwip/priv/memp_std.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/priv/memp_std.h)
- 使用位置：`MEMP_*` typed pools、object sizes 与 counts
- 支撑内容：UDP/TCP PCB、TCP segment、Netconn、tcpip message 等 pool 定义

<a id="source-s3"></a>
### [S3] pbuf allocator routing
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/pbuf.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/pbuf.c)、[`src/include/lwip/pbuf.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/pbuf.h)
- 使用位置：`PBUF_RAM`、`PBUF_POOL`、`PBUF_REF`、`PBUF_ROM`
- 支撑内容：不同 pbuf type 如何路由到 `mem`、`MEMP_PBUF_POOL` 或 `MEMP_PBUF`

<a id="source-s4"></a>
### [S4] UDP PCB allocation
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/udp.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/udp.c)
- 使用位置：`udp_new()` / `MEMP_UDP_PCB`
- 支撑内容：UDP control block 的 typed-pool allocation

<a id="source-s5"></a>
### [S5] TCP PCB/segment allocation 与 reclaim
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/tcp.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/tcp.c)、[`src/core/tcp_out.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/tcp_out.c)
- 使用位置：`tcp_alloc()`、listen PCB、`MEMP_TCP_SEG`、resource-pressure policy
- 支撑内容：TCP typed-pool allocation 与第一次 allocation miss 后的 PCB reclaim strategy

<a id="source-s6"></a>
### [S6] current example memory budgets
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/examples/example_app/lwipopts.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/example_app/lwipopts.h)
- 使用位置：`MEM_SIZE`、各 `MEMP_NUM_*`、`PBUF_POOL_SIZE`、`PBUF_POOL_BUFSIZE`
- 支撑内容：本文具体 sizing 数字只对应当前 example config

<a id="source-s7"></a>
### [S7] lwIP statistics definitions
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/include/lwip/stats.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/stats.h)、[`src/core/stats.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/stats.c)
- 使用位置：mem/memp resource observation
- 支撑内容：按 allocator/pool 统计 used/max/error 的数据结构与 display path

<a id="source-s8"></a>
### [S8] allocator backend options
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/include/lwip/opt.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/opt.h)
- 使用位置：`MEM_LIBC_MALLOC`、`MEM_CUSTOM_ALLOCATOR`、`MEMP_MEM_MALLOC`
- 支撑内容：更换 `mem` backend 或把 typed pools 路由到 heap 时的配置语义与 upstream caveat
