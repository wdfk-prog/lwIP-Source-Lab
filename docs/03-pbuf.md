<meta name="referrer" content="no-referrer" />

# 教程 03：从 `low_level_input()` 到 `pbuf_free()`——`pbuf` 的数据视图、Chain 与引用计数

> 摘要：从 TAP 接收路径里的第一次 pbuf allocation 出发，理解 payload、长度、Chain、类型与引用计数如何共同描述一个 packet。

[TOC]

本文源码块采用统一约定：除非代码块前明确标注为“上游连续源码片段”，其余 C 代码块一律视为按当前 revision 裁剪的“执行路径阅读版”。阅读版只删除与当前主线无关的注释、条件编译或旁支，不重排保留语句，也不使用省略号伪装缺失源码；示意代码会另行标注。

Stage 2 已经看到：TAP 收到一帧后，Unix Port 会把字节复制进 `pbuf`，再交给 `netif->input()`。这一篇不先列 `PBUF_RAM/PBUF_POOL/PBUF_REF/PBUF_ROM` 名词，而是从真实 RX 调用点开始追。[S1](#source-s1)

## 1. `pbuf` 第一次在哪里出现：`low_level_input()`

Unix TAP Port 的 RX 路径不是先创建一个抽象“packet object”，而是先从 TAP fd 读取真实 Ethernet frame，再按读到的长度申请 `pbuf`。下面是当前 upstream `tapif.c` 的连续源码片段：[S1](#source-s1)

```c
static struct pbuf *
low_level_input(struct netif *netif)
{
  struct pbuf *p;
  u16_t len;
  ssize_t readlen;
  char buf[1518]; /* max packet size including VLAN excluding CRC */
  struct tapif *tapif = (struct tapif *)netif->state;

  /* Obtain the size of the packet and put it into the "len"
     variable. */
  readlen = read(tapif->fd, buf, sizeof(buf));
  if (readlen < 0) {
    perror("read returned -1");
    exit(1);
  }
  len = (u16_t)readlen;

  MIB2_STATS_NETIF_ADD(netif, ifinoctets, len);

#if 0
  if (((double)rand()/(double)RAND_MAX) < 0.2) {
    printf("drop\n");
    return NULL;
  }
#endif

  /* We allocate a pbuf chain of pbufs from the pool. */
  p = pbuf_alloc(PBUF_RAW, len, PBUF_POOL);
  if (p != NULL) {
    pbuf_take(p, buf, len);
    /* acknowledge that packet has been read(); */
  } else {
    /* drop packet(); */
    MIB2_STATS_NETIF_INC(netif, ifindiscards);
    LWIP_DEBUGF(NETIF_DEBUG, ("tapif_input: could not allocate pbuf\n"));
  }

  return p;
}
```

这段代码把“Host 文件描述符”和“lwIP packet buffer”真正接起来了：

```text
TAP fd
  | read()
  v
临时连续数组 buf[1518]
  | len = readlen
  v
pbuf_alloc(PBUF_RAW, len, PBUF_POOL)
  | 可能得到一个节点，也可能得到一条 chain
  v
pbuf_take(p, buf, len)
  | 把连续 frame 按 pbuf 节点长度复制进去
  v
p -> 一整个 Ethernet frame 的 lwIP 表示
```

这里一次出现了三个参数，后文所有 `pbuf` 行为都从它们展开：[S1](#source-s1)[S2](#source-s2)

- `len`：这次 `read()` 实际返回的 frame 字节数，不是固定 MTU，也不是某个 pool element 的容量；
- `PBUF_RAW`：当前 RX 数据从最外层 Ethernet Header 开始，因此不额外预留协议头 headroom；
- `PBUF_POOL`：要求从 RX pool 取得承载数据的节点，长度较大时允许形成 chain。

所以这里的 `pbuf_alloc()` 不是普通意义的“申请一个结构体”。它同时决定节点来源、payload 起点和一整个 packet 是否需要跨多个节点。

## 2. `struct pbuf` 到底描述什么

`pbuf` 可以理解为“**一段数据视图 + 一组生命周期元数据**”。当前主线最重要的是七个字段：[S2](#source-s2)

```c
struct pbuf {
  struct pbuf *next;
  void *payload;
  u16_t tot_len;
  u16_t len;
  u8_t type_internal;
  u8_t flags;
  LWIP_PBUF_REF_T ref;
  u8_t if_idx;
};
```

| 字段 | 当前先理解成什么 |
| --- | --- |
| `payload` | 当前这一段可见数据的起点 |
| `len` | 当前这个 pbuf 节点里有多少有效字节 |
| `tot_len` | 从当前节点开始，到这个 packet 末尾一共还有多少字节 |
| `next` | 同一个 packet 的下一段 buffer |
| `ref` | 当前还有多少引用持有这个 pbuf |
| `type_internal` | 这个 pbuf 来自哪类 allocator、payload 有什么属性 |
| `flags/if_idx` | 额外 packet 属性和输入接口索引 |

最容易误解的是 `payload`：它不一定永远指向最初收到的 Ethernet Header。协议层调用 `pbuf_remove_header()` 后，`payload` 可以向后移动，让同一个 pbuf 在下一层看来“从 IPv4 Header 开始”或“从 ICMP/TCP/UDP Header 开始”。

```mermaid
flowchart LR
    A["同一个 pbuf"] --> B["RX 初始<br/>payload -> Ethernet Header"]
    B --> C["ethernet_input()<br/>remove Ethernet header"]
    C --> D["payload -> IPv4 Header"]
    D --> E["ip4_input()<br/>remove IPv4 header"]
    E --> F["payload -> ICMP/TCP/UDP Header"]
```

这也是为什么把 `pbuf` 当普通 `malloc()` buffer 会丢失关键语义。

## 3. 为什么一个 packet 可能需要多个 pbuf

当前 example 配置的 `PBUF_POOL_BUFSIZE` 是 256 bytes，而 Ethernet MTU 可以是 1500 bytes；一个较大的 frame 很自然会横跨多个 pool element。[S3](#source-s3)

关键不是记住“会形成 chain”，而是看 `pbuf_alloc()` 怎样真正做这件事。`PBUF_POOL` 分支从 `MEMP_PBUF_POOL` 循环取节点，每轮只把当前节点能承载的部分写入 `qlen`，直到 `rem_len` 归零：[S4](#source-s4)

```c
    case PBUF_POOL: {
      struct pbuf *q, *last;
      u16_t rem_len; /* remaining length */
      p = NULL;
      last = NULL;
      rem_len = length;
      do {
        u16_t qlen;
        q = (struct pbuf *)memp_malloc(MEMP_PBUF_POOL);
        if (q == NULL) {
          PBUF_POOL_IS_EMPTY();
          /* free chain so far allocated */
          if (p) {
            pbuf_free(p);
          }
          /* bail out unsuccessfully */
          return NULL;
        }
        qlen = LWIP_MIN(rem_len, (u16_t)(PBUF_POOL_BUFSIZE_ALIGNED - LWIP_MEM_ALIGN_SIZE(offset)));
        pbuf_init_alloced_pbuf(q, LWIP_MEM_ALIGN((void *)((u8_t *)q + SIZEOF_STRUCT_PBUF + offset)),
                               rem_len, qlen, type, 0);
        LWIP_ASSERT("pbuf_alloc: pbuf q->payload properly aligned",
                    ((mem_ptr_t)q->payload % MEM_ALIGNMENT) == 0);
        LWIP_ASSERT("PBUF_POOL_BUFSIZE must be bigger than MEM_ALIGNMENT",
                    (PBUF_POOL_BUFSIZE_ALIGNED - LWIP_MEM_ALIGN_SIZE(offset)) > 0 );
        if (p == NULL) {
          /* allocated head of pbuf chain (into p) */
          p = q;
        } else {
          /* make previous pbuf point to this pbuf */
          last->next = q;
        }
        last = q;
        rem_len = (u16_t)(rem_len - qlen);
        offset = 0;
      } while (rem_len > 0);
      break;
    }
```

注意 `pbuf_init_alloced_pbuf()` 收到两个不同长度：

```text
rem_len -> 当前节点的 tot_len
qlen    -> 当前节点的 len
```

这正是 `tot_len` 不变量的来源之一。假设一个 packet 最终由三段组成：

```text
p0.len = 256
p1.len = 256
p2.len = 88
```

那么从每个节点看，“当前 packet 还剩多少数据”分别是：

```text
p0.tot_len = 600
p1.tot_len = 344
p2.tot_len = 88
```

满足下面这个 `pbuf` 链长度不变量；它用于说明字段关系，不是某个函数中的独立执行语句：[S2](#source-s2)

```text
p->tot_len == p->len + (p->next ? p->next->tot_len : 0)
```

```mermaid
flowchart LR
    P0["p0<br/>len=256<br/>tot_len=600"] --> P1["p1<br/>len=256<br/>tot_len=344"]
    P1 --> P2["p2<br/>len=88<br/>tot_len=88"]
```

因此 pbuf **chain** 表示“同一个 packet 被 scatter 到多块内存”，不是“收到了三个 packet”。这一点后面读 `pbuf_take()`、TCP segmentation 和乱序重组时都会反复用到。

## 4. `PBUF_POOL`、`PBUF_RAM`、`PBUF_REF`、`PBUF_ROM` 为什么不能只看名字

现在已经知道 RX 为什么需要多个节点，再看四类 pbuf 就容易很多。[S2](#source-s2)[S4](#source-s4)

| 类型 | `struct pbuf` 与 payload 的来源 | 典型用途 | 生命周期关键点 |
| --- | --- | --- | --- |
| `PBUF_POOL` | `MEMP_PBUF_POOL` 固定池，结构和 payload 连续 | RX | 可以形成 chain；不要长期占满 RX pool |
| `PBUF_RAM` | `mem_malloc()` 一块连续 heap | TX/需要可修改连续存储 | 通常单节点 |
| `PBUF_REF` | `MEMP_PBUF` 只分配描述符，payload 指向外部可变 RAM | 临时引用外部数据 | 若要排队，必须保证外部数据生命周期或复制 |
| `PBUF_ROM` | `MEMP_PBUF` 只分配描述符，payload 指向稳定只读数据 | 长生命周期静态数据 | payload 不由 pbuf 释放 |

这里需要消歧两个概念：

- `PBUF_POOL` 的 “POOL” 指 allocator 来源；
- `pbuf chain` 指多个 pbuf 节点共同描述一个 packet。

一个 `PBUF_POOL` packet 可以是一条 chain；“POOL”和“chain”不是同一维度。

## 5. `pbuf_layer` 不是协议类型

`pbuf_alloc(layer, length, type)` 的第一个参数容易被误解成“我要申请 TCP pbuf/UDP pbuf”。源码里的 enum 直接说明它实际上是 **header headroom 的累计偏移量**：[S2](#source-s2)

```c
typedef enum {
  PBUF_TRANSPORT = PBUF_LINK_ENCAPSULATION_HLEN + PBUF_LINK_HLEN + PBUF_IP_HLEN + PBUF_TRANSPORT_HLEN,
  PBUF_IP = PBUF_LINK_ENCAPSULATION_HLEN + PBUF_LINK_HLEN + PBUF_IP_HLEN,
  PBUF_LINK = PBUF_LINK_ENCAPSULATION_HLEN + PBUF_LINK_HLEN,
  PBUF_RAW_TX = PBUF_LINK_ENCAPSULATION_HLEN,
  PBUF_RAW = 0
} pbuf_layer;
```

因此这些名字描述的是“当前 payload 前面至少要留出多少空间”，而不是 packet 已经属于哪种协议：

```text
PBUF_TRANSPORT
  预留 link + IP + transport header 空间

PBUF_IP
  预留 link + IP header 空间

PBUF_LINK
  预留 link-layer header 空间

PBUF_RAW
  不额外预留，payload 从当前原始数据起点开始
```

它解决的是 TX 时 `pbuf_add_header()` 能否直接把 `payload` 向前移动，而不是协议分发问题。真正“这是 IPv4、TCP 还是 UDP”由 Ethernet `EtherType`、IPv4 `Protocol` 等 header 字段决定。

`layer` 与 `type` 是两个独立轴：

| 参数 | 决定什么 |
| --- | --- |
| `layer` | payload 前的 headroom / 初始 offset |
| `type` | `struct pbuf` 和 payload 从哪里分配、数据属性与 allocator source |

Stage 4 会看到 RX 方向不断 `pbuf_remove_header()`；TX 方向则常常反过来 `pbuf_add_header()`。两者都是在改变同一个 `payload` 数据视图。

## 6. `pbuf_take()` 为什么能跨 Chain 写入

`low_level_input()` 已经有一块连续的临时 `buf[1518]`，而 `PBUF_POOL` 可能返回 chain。`pbuf_take()` 的真实实现并没有要求 `buf` 和 pbuf 一样分段，它沿 `next` 逐节点计算本轮 copy 长度：[S4](#source-s4)

```c
err_t
pbuf_take(struct pbuf *buf, const void *dataptr, u16_t len)
{
  struct pbuf *p;
  size_t buf_copy_len;
  size_t total_copy_len = len;
  size_t copied_total = 0;

  LWIP_ERROR("pbuf_take: invalid buf", (buf != NULL), return ERR_ARG;);
  LWIP_ERROR("pbuf_take: invalid dataptr", (dataptr != NULL), return ERR_ARG;);
  LWIP_ERROR("pbuf_take: buf not large enough", (buf->tot_len >= len), return ERR_MEM;);

  if ((buf == NULL) || (dataptr == NULL) || (buf->tot_len < len)) {
    return ERR_ARG;
  }

  /* Note some systems use byte copy if dataptr or one of the pbuf payload pointers are unaligned. */
  for (p = buf; total_copy_len != 0; p = p->next) {
    LWIP_ASSERT("pbuf_take: invalid pbuf", p != NULL);
    buf_copy_len = total_copy_len;
    if (buf_copy_len > p->len) {
      /* this pbuf cannot hold all remaining data */
      buf_copy_len = p->len;
    }
    /* copy the necessary parts of the buffer */
    MEMCPY(p->payload, &((const char *)dataptr)[copied_total], buf_copy_len);
    total_copy_len -= buf_copy_len;
    copied_total += buf_copy_len;
  }
  LWIP_ASSERT("did not copy all data", total_copy_len == 0 && copied_total == len);
  return ERR_OK;
}
```

把变量对应回当前 TAP frame：

```text
dataptr      -> low_level_input() 的临时 buf
len          -> read() 返回的完整 frame 长度
p            -> 当前正在填充的 pbuf 节点
p->len       -> 当前节点最多参与本轮 copy 的有效范围
copied_total -> 连续源 buffer 已经消费到哪里
```

所以一个 600-byte frame 即使落在三个 pool 节点里，对 `pbuf_take()` 来说仍是一条连续逻辑字节流：

```text
buf[0 .. 255]   -> p0->payload
buf[256 .. 511] -> p1->payload
buf[512 .. 599] -> p2->payload
```

反向操作 `pbuf_copy_partial()` 则把 chain 当作连续数据视图，从指定 offset 复制到调用者的连续 buffer。[S4](#source-s4)

## 7. `ref` 不是“是否正在使用”的布尔值

`ref` 的定义更严格：**等于当前引用这个 pbuf 的指针数量**。[S2](#source-s2)

新分配 pbuf 通常从 `ref = 1` 开始。`pbuf_ref()` 增加引用，`pbuf_free()` 则先减引用；只有减到 0，allocator 对应的内存才真正释放。[S4](#source-s4)

```mermaid
flowchart TD
    A["pbuf_free(p)"] --> B["--p->ref"]
    B --> C{"ref == 0?"}
    C -- "否" --> D["停止释放<br/>仍有其他 owner"]
    C -- "是" --> E["按 alloc source 释放当前节点"]
    E --> F{"还有 next?"}
    F -- "是" --> A
    F -- "否" --> G["结束"]
```

这里的 owner 不是 C++ 智能指针意义上的类型系统 owner，而是 lwIP 用引用计数维护的运行时所有权关系。

## 8. `pbuf_cat()` 与 `pbuf_chain()` 的差别就是 ownership

两者都会把 `t` 接到 `h` 后面并更新 `h` 侧 `tot_len`，但源码把 ownership 差异写得非常直接。[S4](#source-s4)

`pbuf_cat()` 的连续实现是：

```c
void
pbuf_cat(struct pbuf *h, struct pbuf *t)
{
  struct pbuf *p;

  LWIP_ERROR("(h != NULL) && (t != NULL) (programmer violates API)",
             ((h != NULL) && (t != NULL)), return;);
  LWIP_ASSERT("Creating an infinite loop", h != t);

  /* proceed to last pbuf of chain */
  for (p = h; p->next != NULL; p = p->next) {
    /* add total length of second chain to all totals of first chain */
    p->tot_len = (u16_t)(p->tot_len + t->tot_len);
  }
  /* { p is last pbuf of first h chain, p->next == NULL } */
  LWIP_ASSERT("p->tot_len == p->len (of last pbuf in chain)", p->tot_len == p->len);
  LWIP_ASSERT("p->next == NULL", p->next == NULL);
  /* add total length of second chain to last pbuf total of first chain */
  p->tot_len = (u16_t)(p->tot_len + t->tot_len);
  /* chain last pbuf of head (p) with first of tail (t) */
  p->next = t;
  /* p->next now references t, but the caller will drop its reference to t,
   * so netto there is no change to the reference count of t.
   */
}
```

它没有调用 `pbuf_ref(t)`。API contract 是：调用者把自己原来持有的 `t` 引用转交给新的 chain，之后不能再把那份引用当成独立 ownership 使用。

`pbuf_chain()` 则是在相同拼接动作后明确再加一次引用：[S4](#source-s4)

```c
void
pbuf_chain(struct pbuf *h, struct pbuf *t)
{
  pbuf_cat(h, t);
  /* t is now referenced by h */
  pbuf_ref(t);
  LWIP_DEBUGF(PBUF_DEBUG | LWIP_DBG_TRACE, ("pbuf_chain: %p references %p\n", (void *)h, (void *)t));
}
```

因此差异不是“两个函数都能拼链，随便选一个”：

| API | 对 `t->ref` 的影响 | 调用者原引用 |
| --- | --- | --- |
| `pbuf_cat(h, t)` | 不增加 | 转交给新 chain，不应继续作为独立引用使用 |
| `pbuf_chain(h, t)` | `+1` | 调用者仍保留自己的引用，之后仍要负责释放 |

这个区别直接决定以后 `pbuf_free()` 是正常释放、提前释放还是泄漏。

## 9. `pbuf_free()` 为什么可能只释放 Chain 前半段

`pbuf_free()` 不是普通 linked-list destructor。源码先对每个节点执行 `--ref`，只有新值变成 0 才真正释放；一旦遇到仍有引用的节点，就立即停止向后走。[S4](#source-s4)

```c
u8_t
pbuf_free(struct pbuf *p)
{
  u8_t alloc_src;
  struct pbuf *q;
  u8_t count;

  if (p == NULL) {
    LWIP_ASSERT("p != NULL", p != NULL);
    LWIP_DEBUGF(PBUF_DEBUG | LWIP_DBG_LEVEL_SERIOUS,
                ("pbuf_free(p == NULL) was called.\n"));
    return 0;
  }

  count = 0;
  while (p != NULL) {
    LWIP_PBUF_REF_T ref;
    SYS_ARCH_DECL_PROTECT(old_level);
    SYS_ARCH_PROTECT(old_level);
    LWIP_ASSERT("pbuf_free: p->ref > 0", p->ref > 0);
    ref = --(p->ref);
    SYS_ARCH_UNPROTECT(old_level);
    if (ref == 0) {
      q = p->next;
      alloc_src = pbuf_get_allocsrc(p);
#if LWIP_SUPPORT_CUSTOM_PBUF
      if ((p->flags & PBUF_FLAG_IS_CUSTOM) != 0) {
        struct pbuf_custom *pc = (struct pbuf_custom *)p;
        LWIP_ASSERT("pc->custom_free_function != NULL", pc->custom_free_function != NULL);
        pc->custom_free_function(p);
      } else
#endif /* LWIP_SUPPORT_CUSTOM_PBUF */
      {
        if (alloc_src == PBUF_TYPE_ALLOC_SRC_MASK_STD_MEMP_PBUF_POOL) {
          memp_free(MEMP_PBUF_POOL, p);
        } else if (alloc_src == PBUF_TYPE_ALLOC_SRC_MASK_STD_MEMP_PBUF) {
          memp_free(MEMP_PBUF, p);
        } else if (alloc_src == PBUF_TYPE_ALLOC_SRC_MASK_STD_HEAP) {
          mem_free(p);
        } else {
          LWIP_ASSERT("invalid pbuf type", 0);
        }
      }
      count++;
      p = q;
    } else {
      p = NULL;
    }
  }
  return count;
}
```

这里同时完成两件事：

1. **引用计数决定是否能释放**：`ref != 0` 就停止；
2. **allocation source 决定怎么释放**：Pool 回 `memp_free(MEMP_PBUF_POOL)`，描述符型回 `MEMP_PBUF`，`PBUF_RAM` 回 `mem_free()`，custom pbuf 则调用自己的 free callback。

所以：

```text
pbuf_free(head)
```

真正的语义是“从 `head` 开始释放已经失去全部引用的连续前缀”，不是无条件 free 整条 `next` 链。

例如：

```text
p0.ref = 1
p1.ref = 2   <- 还有另一个 owner
p2.ref = 1
```

调用 `pbuf_free(p0)` 后：

```text
p0.ref: 1 -> 0  => p0 被释放
p1.ref: 2 -> 1  => 停止
p2 不会继续 decrement
```

这一点是后续 UDP callback、TCP receive、zero-copy RX 等 ownership 分析的基础。

## 10. Unit Test 在这一阶段应该怎么看

upstream `test_pbuf.c` 提供的是确定性输入：它会显式申请不同 layer/type/length 的 pbuf，检查 chain 长度、不变量、header 调整和 copy 行为。[S5](#source-s5)

它和 TAP RX 的职责不同：

```text
TAP RX
  证明真实 frame 怎样进入 pbuf

Unit Test
  证明 pbuf API 在边界输入下保持哪些不变量
```

后续文章继续看到 `pbuf_cat()`、`pbuf_ref()`、`pbuf_free()` 时，都应该带着这三个问题读：

1. 当前 `payload` 指向哪一层 header？
2. 当前 chain 的 `len/tot_len` 是否仍表示同一个 packet？
3. 当前是谁持有引用，下一步谁负责释放？

## 资料来源

<a id="source-s1"></a>
### [S1] Unix TAP Port RX 路径
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/ports/unix/port/netif/tapif.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/ports/unix/port/netif/tapif.c)
- 使用位置：真实 RX 中 `pbuf_alloc()`、`pbuf_take()` 的入口
- 支撑内容：证明 TAP frame 如何从连续 Host buffer 转成 lwIP pbuf

<a id="source-s2"></a>
### [S2] `struct pbuf` 与类型定义
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/include/lwip/pbuf.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/include/lwip/pbuf.h)
- 使用位置：字段、Chain 不变量、`PBUF_*` 类型
- 支撑内容：`payload/len/tot_len/ref/next` 语义与 allocator/type flags

<a id="source-s3"></a>
### [S3] example `lwipopts.h`
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`contrib/examples/example_app/lwipopts.h`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/contrib/examples/example_app/lwipopts.h)
- 使用位置：`PBUF_POOL_BUFSIZE` 等当前 example 配置
- 支撑内容：当前 Host example 的 pool buffer 配置基线

<a id="source-s4"></a>
### [S4] `pbuf` Core 实现
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`src/core/pbuf.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/src/core/pbuf.c)
- 使用位置：allocation、copy、reference、chain、free
- 支撑内容：`pbuf_alloc()`、`pbuf_take()`、`pbuf_copy_partial()`、`pbuf_ref()`、`pbuf_cat()`、`pbuf_chain()`、`pbuf_free()` 的真实行为

<a id="source-s5"></a>
### [S5] upstream `pbuf` Unit Test
- 版本：`d08f4773edd0182b7910fc8f046eed82ffcd67c9`
- URL/文档：[`test/unit/core/test_pbuf.c`](https://github.com/lwip-tcpip/lwip/blob/d08f4773edd0182b7910fc8f046eed82ffcd67c9/test/unit/core/test_pbuf.c)
- 使用位置：确定性边界输入与 API 不变量
- 支撑内容：upstream 如何直接构造 pbuf case 检查 allocation、chain、header 与 copy 行为
