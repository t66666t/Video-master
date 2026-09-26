# 哔哩哔哩在线播放：复核结论与修复计划

> 范围：哔哩哔哩在线卡片（`MediaSourceKind.bilibiliStream`）从打开、缓存、切页、后台到“后台播放哔哩哔哩时只加载音频”的完整链路。
> 不涉及：本地文件播放、下载/合成（materialization）流程本身、yt-dlp。
> 本文档只做分析与方案，不含代码改动。

---

## 0. 结论先行

1. **最根本的问题在本地网关**（`lib/services/bilibili/bilibili_streaming_service.dart` 的 `_proxyActiveTrack` / `_tryServeCachedTrack`），不在播放页。网关把 CDN 数据用 `response.add()` 直接塞给 libmpv：
   - 没有背压：CDN 下多快，网关就往内存里塞多快，与 libmpv 读多少无关；
   - libmpv 断开连接（每次 seek、切清晰度、切集）后，网关**不会**停止从 CDN 下载，会一直下到这段 Range 的末尾（对开放区间 `bytes=X-` 来说就是整个文件的剩余部分）；
   - 这些“僵尸下载”共用一个 `maxConnectionsPerHost = 8` 的 `HttpClient`，几次 seek 之后新的 Range 请求就要**排队等僵尸下载完**。

   “已缓存部分加载慢”“缓存时黑屏/卡住”“莫名其妙没声音”“只加载音频不省流量”这四类现象，都能在这条链路上找到直接原因。
2. 上一轮分析里有几条**说错了或说重了**，第 1 节逐条更正。
3. 修复分 5 个阶段：阶段 0 只加观测和复现测试；阶段 1（网关数据流）收益最大，可以独立发布；后面的阶段依赖它，按顺序做。每个阶段都列出可能引入的新问题和规避方法（第 3 节），以及阶段之间的相互影响（第 4 节）。

---

## 1. 上一轮结论复核

| # | 上一轮结论 | 复核结果 | 说明 |
|---|---|---|---|
| 1 | 缓存只在整段收完才提交，seek 中途断开就整段丢弃 | **部分成立，机制说错** | 客户端断开后上游并不会停，会继续下完整段再提交（见 N2）。真正丢弃发生在：缓存策略被关闭（`disableCacheWriter` 删除临时文件）、CDN 中途出错、进程退出。并且策略关闭后，这条连接余下的数据**永远不再写缓存**（`cacheDisabled` 不可恢复，见 N7）。 |
| 2 | 提交时持有缓存锁，挡住命中查询 | 成立 | `_commitTrackCacheSegment` 在 `_runCacheOp` 内把整段临时文件拷进 `.track`，和 `_tryServeCachedTrack` 查计划用同一个 key。 |
| 3 | 缓存键不含 `codecid`，可能混写两种编码 | 成立，**但概率低** | `_selectVideo` 在同一 qn 下固定优先 AVC，正常情况下同一张卡的编码是稳定的。只有接口返回的编码集合变化时才会混写，但混写后损坏是永久的。保留为防御性修复。 |
| 4 | 桌面端总是跳过 `cache-pause-initial`，导致起播黑屏 | **不成立（作为黑屏主因）** | 首帧前有封面遮罩。真正没被遮住的是“控制器可挂载”到“readiness 开始遮罩”之间的窗口（见 N12）。`cache-pause-wait=0.35` 造成的是卡顿循环（刚缓冲一点就恢复，马上又卡），不是黑屏。 |
| 5 | 起播连续多次 seek | 成立 | `start=` → native 层选轨后 seek → `_seekInitialPosition` → `_confirmInitialResumePosition`（最多两次）。 |
| 6 | 重新启用视频轨后 `cache-pause=no` 永久残留 | **成立，而且比说的更严重** | 同时残留的还有 `cache-pause-wait=0`、`hr-seek=yes`。`_prepareSeekStyle` 按 `_streamingSeekStyles[textureId]` 缓存“上次设置的档位”，档位没变就直接返回，所以后面的 seek 也不会把它们改回来。后果主要是卡顿、音画不同步和静音，不是黑屏。 |
| 7 | 视频轨命令返回就立刻揭掉封面 | 成立 | `_syncBilibiliVideoTrackPolicy` 在 `applied` 后 `_endCoveringUntilVisibleVideoFrame(immediate: true)`；`vid` 是 `waitForInitialization: false` 设下去的，此时通常还没有新帧。 |
| 8 | Mini → 页面时视频轨已开，不盖封面导致黑屏 | **基本不成立，撤回** | 桌面端的 texture 一直在接收帧，挂上 `VideoPlayer` 就是最新画面。只有 Android 后台创建、之后才挂输出的情况例外（`ensureVisibleVideoOutput` 挂上就揭封面），并入 V1/V2 处理。 |
| 9 | 进页可见性占位最多 12 帧，可能被提前撤掉 | **不成立，撤回** | `RouteObserver.subscribe` 会立即回调 `didPush`，`_initVideoInternal` 里也会登记，12 帧绰绰有余。 |
| 10 | 精确 seek 用 `hr-seek=default`，视频落关键帧、音频等待，导致没声音 | **不成立，撤回** | media_kit 的 seek 是 `absolute`；mpv 的 `default` 对 absolute seek 本来就是精确的。 |
| 11 | `bilibili_zero_resync` seek 冲掉音频缓冲 | **大幅弱化** | 重新启用视频前有 `_armInitialPositionGuard(_position)`，2 秒内的 0 样本会被忽略。仍有触发可能，但不是主要原因。 |
| 12 | 初始化后的解码/音轨错误被吞掉 | 成立 | `shouldForwardPlayerError` 在初始化后、只要有时长和轨道就不转发，也没有任何恢复动作。 |
| 13 | 专辑封面判定会误关视频轨 | **基本不会发生，降为零风险防御项** | 外挂音轨在主文件加载后才 `audio-add`，此时轨道列表里已经有视频轨，`hasMotionVideo` 为真。 |
| 14 | “只加载音频”走的是 `deferVideo`，`audioPrimary` 是死代码 | 成立 | `_createBilibiliStreamController` 只有一个调用点，从不传 `audioPrimary: true`，`_bilibiliAudioPrimaryPlayer` 永远是 false。 |
| 15 | `deferVideo` 仍用视频档缓冲参数 | 成立，**但影响小** | 真正的问题是 N6：视频数据照样被网关整段拉走。 |
| 16 | 播放页还在栈里时切到后台，视频照常下载 | 成立 | 这是有意的取舍（注释说是为了避免回前台黑一下），与设置文案冲突，需要决策（B3）。 |
| 17 | 播放页上弹对话框会触发 `didPushNext`，关掉视频轨 | **不成立，撤回** | `AppToast.routeObserver` 是 `RouteObserver<PageRoute>`，对话框、底部弹窗都不是 `PageRoute`。只有整页路由盖上来才会触发，这是预期行为。 |

---

## 2. 新发现的问题

置信度：**高** = 代码路径确定；**中** = 取决于某个运行时行为，需要实测；**低** = 边缘情况。

### N1　网关无背压，内存随下载速度增长（严重，高；需测试确认）

`_proxyActiveTrack`：

```dart
await for (final bytes in upstream) {
  downstream.response.add(bytes);          // 不等待消费
  if (!cacheDisabled) sink?.add(bytes);
  _recordGatewayTransfer(session.itemId, bytes.length);
}
```

Dart 的 `HttpResponse.add` 不提供背压：socket 写不动时，数据堆在 IOSink 内部的 StreamController 里，没有上限。libmpv 按 `demuxer-readahead-secs` 读够 12～16 秒就停止读 socket，但网关会继续以 CDN 速度把整个剩余文件读进内存。

- 桌面：1080p 大文件时进程内存可能涨到几百 MB，GC 压力导致 UI 掉帧。
- Android 后台：内存暴涨会被系统杀进程，表现是“后台播着播着突然停了、没声音了”。
- 网速显示（`_recordGatewayTransfer`）统计的是 CDN 进网关的速度，不是播放器实际消费的速度，所以会有“速度忽高忽低”的现象。代码注释里已经提到过“bursty fake speed”。

复现方式：假 CDN 返回 50MB，客户端只读 1MB 就停住。统计上游已发送的字节数和网关进程的 RSS。

### N2　客户端断开、会话关闭都不会取消上游下载（严重，高）

- libmpv/ffmpeg 在 demuxer 缓存以外的位置 seek 时，会关掉旧连接、另开一个 `Range: bytes=新位置-`。网关这边 `response.add` 往已关闭的 socket 写入**不会抛异常**，`await for (final bytes in upstream)` 会一直跑到上游结束。
- `session.close()` 只设置一个标记；`_releaseSessions` 用 `waitUntilIdle().timeout(3s)` 等待后就返回，传输本身仍在继续。
- 结果是：每次 seek、切清晰度、切集都会留下一个“僵尸下载”，它会下完文件的剩余部分。如果缓存策略仍允许（例如同一张卡切清晰度时，旧清晰度的会话 `session.itemId == itemId && allowed`），它还会把旧清晰度整个文件写进缓存。

### N3　僵尸下载占满连接池，新请求排队（严重，N2 的直接后果，高）

`_createMediaClient()` 设置了 `maxConnectionsPerHost = 8`，所有会话、预热、僵尸下载共用这一个 client，而视频和音频通常在同一个 CDN 主机上。连续 seek 三四次之后，新的视频/音频 Range 请求就要**等某个僵尸下载把整个文件下完**才能拿到连接。

这就是“拖动进度条后长时间卡住/黑屏”“缓存过程中出问题”的主要原因。如果排队的是音频请求，而视频还有 demuxer 缓存（并且因为第 1 节第 6 条 `cache-pause` 已经被改成 `no`），就会出现**画面在走、没有声音**。

### N4　命中磁盘缓存时一次性读出整段连续缓存（严重，高）

`_tryServeCachedTrack` 处理开放区间请求时 `sliceEndInclusive = contiguousEnd - 1`，然后：

```dart
while (remaining > 0) {
  final chunk = await raf.read(chunkSize);
  downstream.response.add(chunk);   // 同样没有背压
  remaining -= chunk.length;
}
```

如果之前连续缓存了 300MB，每次 seek 进这段范围，网关都会按磁盘速度把 300MB 全部读进内存。libmpv 断开后这个循环也不会停，多次 seek 会叠加成多个并行的整段磁盘读。“已经缓存好的部分加载慢”最直接的原因就在这里：磁盘和内存都被之前的读取占满了。

### N5　只命中一部分时，给开放区间请求返回“短 206”（中～高，取决于 libmpv 是否开启 reconnect）

请求 `bytes=X-`，但缓存只覆盖 `X..C`（C 小于文件末尾）时，网关返回 `206 bytes X-C/total`，然后关闭响应。ffmpeg 的 http 协议按 `total` 计算预期结尾，会报 `Stream ends prematurely` 并返回 EIO：

- 如果 libmpv 开启了 `reconnect`：会在 C 处重连，多一次往返，勉强能播。
- 如果没有开启：这条轨道直接 EOF。**音轨提前 EOF 就是“画面在走、没声音”**，视频轨提前 EOF 就是画面停住或黑屏。

有界请求 `bytes=A-B` 只覆盖一部分时也是同样的情况。验证方法：在 mpv 日志里搜索 `Stream ends prematurely` 和 `Will reconnect`。

### N6　“只加载音频”时，视频照样被网关整段拉走（严重，N1 + N2 的后果，高）

`deferVideo` 只是把 `vid` 设成 `no`，主文件 `/video` 仍然会被打开（需要读 init/sidx）。ffmpeg 发出 `Range: bytes=0-` 后就不再读了，但网关会按 N1 的方式**把整个视频文件从 CDN 拉进内存**；如果 Mini 正在播放，缓存策略允许，还会写进磁盘。这个设置目前基本没有省流量。

### N7　缓存策略关闭时，进行中的写入被删除，并且之后不再恢复（中～高，高）

- `updateCachePolicy` 的条件：前台且有播放页，或者 (Mini/通知可见 **且** 正在播放)。
- 不满足时，`disableCaching()` → `disableCacheWriter` → `closeCache(delete: true)`：**正在写的临时文件被删除**；`cacheDisabled = true` 之后这条传输再也不会写缓存，即使策略马上又变回允许。
- 在 Windows 上，`hidden`（最小化）会被判定为后台，而桌面端没有通知栏 → 最小化一次，当前这条线性读取的剩余部分就都不会进缓存。在 Mini 里暂停一下也是同样的效果。
- libmpv 线性播放时一直复用同一条连接，所以“暂停/最小化一次之后，后面看的内容全都没有缓存”。

### N8　CDN 对 Range 请求返回 200 时，缓存写到错误偏移（低概率，但会永久损坏）

`_byteRangeFromContentRange` 在没有 `Content-Range` 时使用 `fallbackStart = 请求的 start`。但 200 响应的内容是从第 0 个字节开始的整个文件，这样会把整文件写到 `start` 偏移处。B 站 CDN 正常都会遵守 Range，但一旦出现，这张卡的缓存就会永久损坏：播到那一段就黑屏或没声音，直到清除缓存。

### N9　清缓存与提交没有互斥，可能让索引指向零填充数据（低概率，永久损坏）

`clearCache()` 不经过 `_runCacheOp`。时序：清缓存删除了 `.track` → 一个进行中的 `_commitTrackCacheSegment` 读到**尚未删除的旧索引** → `truncate` 重新创建出零填充文件，只写入新的一段 → 持久化“旧区间 + 新区间”的索引。之后旧区间命中时返回的全是 0。

### N10　会话按“获取时间”超过 3 小时就被清理，可能清掉正在播放或预热中的会话（中低，高）

`_pruneSessions` 在每次 `prepare` 时，按 `obtainedAt < now - 3h` 删除会话，不考虑是否正在使用：

- 长时间暂停后（例如过夜）切清晰度 → `prepare` → 当前会话被移出 `_sessions` → 当前播放器的下一个 Range 收到 410，轨道结束。
- `_warmPlaybacks` 里的预热会话被清理后，仍然留在 map 中 → 下一集取到的是一个已经失效的 playback → 第一次打开失败，要等重试才能播，这段时间就是一次“黑屏起播”。

### N11　上游中途出错时，网关没有自己续传（中，高）

CDN 连接中途重置（长时间播放、移动网络切换时常见）时，`await for` 抛出异常，响应被截断，结果与 N5 相同：能不能恢复取决于 ffmpeg 的 reconnect。截断的是音轨时，就是“没声音”。

### N12　播放页挂上 texture 的时间早于封面开始遮盖的时间（中～高，进页黑屏的主因之一，高）

- `play()` 在 `initialize()` 之后立即进入 `controllerMountable` 阶段，页面的 `_initVideoInternal` 在 `hasMountableController` 为真时就会挂上 `VideoPlayer`，即使 state 仍是 loading。
- 封面要到 `_awaitPlaybackReadinessResult` 才开始盖，这之前还要经过 `_seekInitialPosition`（pause + seek，最长 2 秒超时）、`_awaitBilibiliVideoTrackPolicy`、`_confirmInitialResumePosition`、`play()`。
- 这个窗口里 texture 已经挂上，但没有帧（黑），或者先显示一帧 t=0 的画面再跳到续播点。
- `_hasDecodedVideoTexture` 这个名字有误导性：它只检查 `isInitialized`，并不代表已经解码出画面。

### N13　桌面端首帧之后才调整纹理尺寸（中，需实测）

`videoParams` 事件后 20ms，`_scheduleAdaptiveOutputResize` 调用 `controller.setSize(...)` 重建 texture。首帧信号可能早于这次 resize → 封面已经揭掉 → resize 后到下一帧之间是黑的。**如果是暂停状态进页**（关闭了进页自动播放），可能要到下一次解码才会出现画面，也就是一直黑。需要用“进页不自动播放”的场景实测确认。

### N14　视频轨策略的“已请求状态”没有和具体的 controller 绑定（低，高）

`_requestedBilibiliVideoTrackEnabled` 是全局字段。清晰度切换时换了新 controller，这个字段不会重置；如果新 controller 的实际状态和它不一致，`_syncBilibiliVideoTrackPolicy` 会直接 `return`，导致策略失效（例如开启“只加载音频”时，在 Mini 中切换清晰度，新 controller 会一直下载视频）。

### N15　每个 Range 请求都要列目录并读索引 JSON（低，性能）

`_openTrackCacheStore` → `_ingestLegacySegFiles` 对每个请求都会 `itemDir.list()`，然后读取并解析 `.track.json`。seek 频繁时会带来额外的磁盘 IO 和延迟。

### N16　稀疏文件扩展可能真实占用磁盘（中，需实测）

`_writeBytesIntoTrackFile` 用 `truncate(endExclusive)` 把文件扩展到最大偏移。在 NTFS 上（没有设置 sparse 标志）扩展会预留实际的磁盘空间。拖到 90% 处看一眼，就可能产生一个接近整个文件大小的 `.track`；缓存管理页面显示的占用也会偏大。先实测，再决定是否在后续改为分块存储（本计划不强制）。

---

## 3. 修复方案

原则：
- 每一项都说明**改什么、为什么、可能引入什么新问题、怎样规避、会影响哪些其他逻辑**；
- 每个阶段都能独立回滚；阶段 1 用内部开关（例如 `BilibiliStreamingService.useGatewayV2`，默认在 debug 中开启）包住，出问题可以一键切回旧实现；
- 仓库里有不少“读源码字符串”的测试（例如 `test/bilibili_gateway_transfer_speed_test.dart` 检查 `_tryServeCachedTrack` 中 `_runCacheOp` 与 `raf.read` 的顺序，`test/media_playback_session_state_test.dart` 检查 `startWithoutVideo: audioPrimary || deferVideo` 等）。重构会让它们失败。**必须先把这些测试背后要保护的意图改写成行为测试，再修改实现**，不能直接删除断言。

### 阶段 0：可观测性与复现测试（不改变行为）

| 项 | 内容 |
|---|---|
| O1 | 网关为每个请求分配 id，debug 日志记录：轨道（video/audio）、Range、数据来源（disk / cdn / 混合）、实际发送字节数、耗时、结束原因（完成 / 客户端断开 / 会话关闭 / 上游错误）。 |
| O2 | 定期打印活跃传输数和每个 CDN 主机占用的连接数。 |
| O3 | 打开 libmpv 日志中 `ffmpeg`/`stream` 模块的 warn 级别，确认是否出现 `Stream ends prematurely`、`Will reconnect`，以及 libmpv 是否开启了 `reconnect`（决定 N5 / N11 的实际严重程度）。 |
| O4 | 复现测试（使用现有的 `_FakeBilibiliApiService` 和本地假 CDN）：慢读客户端（验证 N1）；读 1KB 后断开（验证 N2，断言上游发送的字节数）；开放区间请求只命中部分缓存（验证 N5）；200 响应（验证 N8）。 |
| O5 | 手工确认 N13（暂停进页）和 N16（NTFS 上 seek 到文件末尾后查看 `.track` 的实际占用）。 |

风险：只增加日志和测试。日志只在 `kDebugMode` 下输出，避免 release 中每个 chunk 都做字符串拼接。

### 阶段 1：网关数据流（解决 N1–N11、N15）

#### G1　背压 + 断开即取消 + 会话关闭时主动取消

改动：
- 把 `await for ... response.add(...)` 改成 `await downstream.response.addStream(body)`，`body` 是一个 `async*` 生成器。下游暂停时生成器停在 `yield` 上，不再从上游读取，TCP 窗口关闭，CDN 自然减速。
- 每个请求创建一个 `_TrackTransfer`，登记到 session。`session.close()` 会取消其中所有传输（对上游调用 `HttpClientRequest.abort()` 或取消 response 订阅）。`_releaseSessions` 的 `waitUntilIdle` 因此会很快完成。
- 监听 `downstream.response.done` 的错误和 `addStream` 的结束，客户端断开时立即取消对应的上游请求。
- 在网关内部加一个**有上限的预读缓冲**：上游最多领先下游 H 字节（建议桌面 8MB、移动端 4MB），超过就暂停上游，低于 H/2 再恢复。

为什么要有 H：现在网关把整个文件都读进内存，客观上起到了一个巨大缓冲的作用，在网络抖动时反而更流畅。直接改成严格背压，抖动网络下卡顿可能变多。H 在保留一部分缓冲效果的同时限制了内存。

可能引入的新问题与规避：
- **每次 seek 都要重新做 TLS 握手**：被取消的连接不能再放回连接池复用。原来的僵尸连接同样不能复用，还一直占着连接池，所以整体仍是改善。可选优化：剩余量小于 256KB 的上游直接读完再释放，以便复用连接。
- **CDN 对空闲连接超时断开**（背压导致连接长时间没有读取）：由 G4 的“懒续传”处理，下游真正需要数据时再在当前偏移重新打开上游。
- **网速显示变低**：现在显示的是真实的消费速度。UI 文案不需要改，但使用 `bilibiliGatewaySpeedLabel` 的地方要确认没有依赖“速度大于某个阈值”的判断逻辑（目前 `shouldShowBilibiliBufferingOverlay` 恒为 false，不受影响）。
- **缓存行为变化**：原来因为僵尸下载，“看一眼就可能把整个文件缓存下来”；修复后只缓存实际读到的内容加上 H。这是一个**用户能感知到的行为变化**，要在第 6 节确认是否接受。需要整片离线应走下载/合成功能，不应该靠网关的副作用。
- **`clearCache()` 目前约定“不关闭会话”**（有测试 `clearing cache keeps the gateway session alive`）：G1 只在客户端断开或会话关闭时取消，清缓存只停止写缓存，不取消传输，所以这个约定保持不变。

影响的逻辑：`_recordGatewayTransfer` 和传输速度测量、`releasePlayback` / `releaseItem` 的耗时、清晰度切换中旧会话的释放（会真正停止）。

测试：慢读客户端的内存和上游字节数受 H 限制；断开后 1 秒内上游被取消；`releasePlayback` 后旧会话没有传输；HEAD 请求不受影响；现有 `bilibili_streaming_models_test.dart` 中的网关测试全部通过。

#### G2　缓存改为“边收边写”，按实际写入的字节发布

改动：
- 上游数据到达时，直接按偏移写入 `.track`（每个传输持有一个 `RandomAccessFile`），**先写数据，再把 `[start, 当前偏移)` 更新到内存索引**；索引每 1MB 或 1 秒防抖持久化一次，传输结束时再持久化一次。不再使用 `.seg.tmp` 临时文件和“整段拷贝后再提交”的方式，G2 同时解决了第 1 节第 2 条的持锁问题：锁只包住索引更新，耗时是微秒级。
- 缓存策略关闭时：**停止写入，但保留并持久化已经写入的部分**（不删除）。策略恢复时，同一个传输从当前偏移开始新的一段继续写入（解决 N7）。
- 清缓存时：丢弃（见 G6）。
- 写入失败（磁盘满、权限问题）时，只停止这个传输的缓存写入，不影响播放。

可能引入的新问题与规避：
- **两个传输写同一区间**：同一个缓存键下内容相同（G5 保证），重复写入无害，索引合并即可。
- **读者读到正在写的区域**：读者只按已经发布到索引的区间读取；数据写完才发布，所以安全。
- **崩溃一致性**：数据写入先于索引发布，崩溃只会产生“有数据但没有索引”的情况，不会出现“有索引但没有数据”。不做 fsync，系统崩溃（而非应用崩溃）时可能丢最后一小段，可以接受。
- **Windows 文件句柄**：写入方持有句柄时，删除会失败。清缓存流程必须先关闭写入方（G6）。
- **兼容旧数据**：旧的 `.seg` / `.seg.tmp` 在打开某张卡时迁移一次，并记录已处理，之后不再重复（同时解决 N15）；迁移失败就直接删除旧文件。
- **`hasReusableTrackCache`**：改为“索引非空”，而不是“存在 `.track` 文件”，避免残留的空文件触发快速起播。

影响的逻辑：`inspectItemCacheBreakdown` / `inspectCacheForItem` 的统计（文件名后缀不变，统计逻辑不需要改；如果 N16 实测确认存在，要把显示改为索引中区间的总和）、`_activeCacheFiles` 的用法（从临时文件改为正在写的 `.track`）。

#### G3　拼接响应：磁盘 + 上游放在同一个响应里，不再返回“短 206”

改动：生成器以当前位置 `p` 循环：
1. 如果 `p` 在缓存中：从磁盘按 64KB 块读到这段连续缓存的末尾（或请求的末尾）；
2. 否则：向上游请求 `bytes=p-(下一个缓存区间的起点 - 1，或请求的末尾)`，这是一个有界请求，同时写穿缓存；
3. 直到请求的末尾。

响应头在开始时一次性确定：`206`、`Content-Range: bytes S-E/T`、`Content-Length: E-S+1`。`T` 来自索引里保存的 `totalBytes`（第一次从 CDN 拿到后就持久化）。

- `T` 未知时（第一次打开）：退回“只走上游”的方式（仍然带 G1/G2 的改进）。
- 上游返回的 `Content-Range` 起点或总长度与预期不一致时：终止这次响应，**并清空这条轨道的缓存**（说明缓存和 CDN 上的文件对不上）。

可能引入的新问题与规避：
- **`Content-Length` 必须和实际发送的字节数完全一致**，否则 ffmpeg 会报错。在测试里覆盖：纯磁盘、纯上游、磁盘→上游→磁盘→上游、区间边界差 1 字节等情况。
- **上游返回 200**：按 G6 规则处理，不缓存；拼接场景下直接终止（交给 ffmpeg 重试）。
- **复杂度上升**：生成器的状态机要写成单独的类，用单元测试覆盖；不要在 `_proxyActiveTrack` 里继续堆分支。

效果：命中部分缓存时不再依赖 ffmpeg 的 reconnect（解决 N5）；缓存和网络可以无缝衔接；每次只读实际需要的磁盘数据（结合 G1，解决 N4）。

#### G4　上游中途出错时懒续传

改动：G3 的循环中，上游出错时如果下游仍然连接着，就在当前偏移 `p` 重新打开上游，最多重试 3 次（间隔 0 / 250ms / 1s）；收到 401/403/404 时先 `_refreshSession`（沿用现有的 `didRefreshAfterFailure` 限制）。重试用完后结束响应，交给 ffmpeg 处理。

规避：
- 只有下游在拉取数据时才重试（生成器天然是懒执行的），暂停时不会主动重连；
- 下游已经断开或会话已经关闭时，不再重试；
- 重试次数有上限，不会因为永久性错误无限循环。

效果：解决 N11，同时覆盖 G1 带来的“CDN 空闲超时断连”。

#### G5　缓存键加上编码，并校验文件指纹

改动：
- 前缀改为 `video_{id}_c{codecid}`；音频使用 `audio_{id}`（B 站音频 id 已经区分了码率和杜比/Hi-Res，不需要加 codecid）。
- 索引中额外记录 `codecs` 和 `totalBytes`。第一次从 CDN 拿到 `Content-Range` 总长度时，如果与索引不一致，清空这条轨道再继续。
- `_refreshSession` 刷新后，如果选中轨道的 id 或 codecid 与刷新前不同：保持原轨道（从新的 streamInfo 中找同 id + codecid 的轨道）；找不到时，让这个会话失效（返回 410，播放层走错误恢复重新打开），**不能在同一个 `/video` 地址下中途换成另一个文件**。

规避：
- 旧前缀 `video_{id}` 的缓存无法确定编码，打开卡片时删除一次。**这意味着升级后第一次打开每张卡都会丢失原有缓存一次**，需要在更新说明中提到。
- `clearCacheForItemOnDisk` 按目录删除，不受前缀变化影响；materialization 的文件名是 `materialized_*`、`transcription_audio*`，不冲突。

#### G6　200 响应与清缓存的一致性

改动：
- 请求带了 Range 但上游返回 200 时，这段内容的起点是 0；如果请求的起点大于 0，这次**不写缓存**，数据透传给下游（与现在一致）。
- 每张卡维护一个缓存“代次”：清缓存时先递增代次、关闭所有写入方，然后**先删除 `.track.json`，再删除 `.track`**；写入方每次发布索引前检查代次，变化了就停止。
- 如果 `.track.json` 删除失败，就不删除这个 `.track`（保证索引与数据一致）；如果 `.track` 删除失败（Windows 上读者还持有句柄），在索引中标记失效，稍后重试删除（参考 materialization 的 `pending_delete` 机制）。

效果：解决 N8、N9。

#### G7　会话清理按“最后活动时间”，并且不清理正在使用的会话

改动：
- `_GatewaySession` 增加 `lastActivityAt`（每个请求都更新），清理条件改为 `lastActivityAt` 早于 3 小时前，并且**不是当前播放的会话**（由 `MediaPlaybackService` 通过 `pinPlayback` / `unpinPlayback` 标记）。
- 会话被清理时，同时从 `_warmPlaybacks` 中移除对应的条目；`_takeWarmPlayback` 取出条目时检查会话是否仍然存在。

规避：被标记为正在使用的会话，在切集或切清晰度提交后要及时取消标记，否则会一直留在内存中（占用很小，但要在 `releasePlayback` 中统一处理，避免遗漏）。

效果：解决 N10。

#### G8　索引放进内存

改动：每条轨道的索引在进程内缓存（按 itemId + 前缀），只在第一次打开时读 JSON；旧文件迁移在每张卡上只执行一次。

规避：只有网关会写 `.track`（materialization 使用独立的文件名），不存在别的进程或服务写入导致内存索引过期。清缓存时同时清除内存索引。

### 阶段 2：画面遮罩（解决 N12、N13，以及第 1 节第 7 条）

#### V2　（先做）native 层提供“这次之后的下一帧”信号

现在只有 `firstFrameRenderedFor`，它只触发一次，重新启用视频轨、首次挂上输出之后都没有可以等待的信号。

改动：在 `NativeVideoPlayerMediaKit` 中增加 `nextVideoFrameFor(playerId, {timeout})`：记录调用时 mpv 的 `estimated-frame-number`，轮询（约 16～33ms 一次）直到它变化，或者 `video-out-params` 从空变为有值且时钟已经推进；超时后返回 false。

规避：
- **先做 spike**，确认 media_kit 自带的 libmpv 支持这些属性。不支持时退回“固定延迟 250ms”（仍然比现在“命令返回就揭掉”好）。
- 暂停状态下不会产生新帧：现有的启用路径在暂停时会“播放 80ms 再暂停”来拿到一帧，V2 的等待与之兼容；另外有超时兜底，不会让封面一直留着。
- 轮询只在等待期间进行，有超时，不会长期占用资源。

#### V1　封面从“页面可见且控制器可挂载”开始，到“目标位置的第一帧”结束

改动：
- 对哔哩哔哩的视频卡，在 `play()` 创建新 controller 时，如果有可见的播放页（或导航占位），在进入 `controllerMountable` **之前**开始遮罩；等起播定位完成、并且 V2 报告出现新帧之后才揭掉（保留现有的 8 秒安全超时）。
- `_syncBilibiliVideoTrackPolicy` 在 `applied` 后不再立即揭掉，改为等待 V2 的信号。
- `ensureVisibleVideoOutput` 挂上输出后，同样等待 V2 的信号。

规避：
- **清晰度切换不要走 V1**：它有自己的预热帧逻辑（`_waitForWarmStreamFrame` / 相位锁定），套上 V1 会在已经有画面的时候再盖一次封面。
- **本地文件不改**：只对 `bilibiliStream` 生效。
- 自动播放时，音频可能会比封面揭掉早几百毫秒开始，这是可以接受的，比黑屏好。
- 没有本地缩略图时，封面是 `0xFF141414` 的深色块，看起来仍然像黑屏。需要确认哔哩哔哩卡片在导入时是否都下载了封面；缺失的，在播放前补下载（不在本计划的必做范围内，列为建议）。
- 加载页的封面是全屏 `BoxFit.cover`，而视频区域内的封面是按视频比例缩放的，切换时画面会跳一下。建议两者使用同样的布局（纯 UI 调整，风险很低）。

#### V3　桌面端在创建时就确定纹理尺寸（N13 实测确认后再做）

改动：B 站播放信息里已经有所选视频轨的宽高。创建 `VideoController` 时就按 `adaptiveTextureSize` 计算出的尺寸传入 `VideoControllerConfiguration(width, height)`，并预先写入 `_outputVideoSizes`，使后续 `videoParams` 触发的调整因为尺寸相同而直接跳过。

规避：窗口大小变化的行为不变（现在本来就只在 `videoParams` 时调整）；清晰度切换时新 controller 按新的宽高计算；Android 不支持调整尺寸，保持原样。

### 阶段 3：libmpv 状态与起播 seek、音频健壮性

#### M1　重新启用视频轨之后恢复 libmpv 属性

改动：
- `_configureStreamingBuffer` 时记录每个播放器的原始值（`cache-pause`、`cache-pause-initial`、`cache-pause-wait`、`hr-seek`）。
- `_prepareVideoTrackJoinPreservingAudio` 之后，等 V2 的新帧信号（或者 1.5 秒），并且 `demuxer-cache-duration` 不少于约 1 秒时，恢复这些原始值，并执行 `_streamingSeekStyles.remove(textureId)`，让下一次 seek 重新应用对应档位。
- 如果到时间时视频缓冲仍然不足，每 500ms 再检查一次，最多 5 秒，之后强制恢复。

规避：过早恢复 `cache-pause=yes` 会让音频在视频缓冲没满时停住，这正是原来的“Mini 音频打顿”问题，所以恢复必须等缓冲足够。这一项要在 Mini → 页面、切换后台只加载音频开关这两个场景下专门回归“音频是否打顿”。

#### M2　起播时的定位合并为一次

改动：native 层在完成“选轨后 seek 到 startMs”后，记录 `startupPositionApplied = startMs`。`_seekInitialPosition` 只有在**规范化后的目标等于 startMs**、并且 native 读到的 `time-pos` 与目标的差距在容差内时才跳过；`_confirmInitialResumePosition` 保留，作为最后的安全检查。

规避：
- **接近片尾的续播点会被规范化为 0**：此时目标不等于 startMs，必须照常 seek，否则会停在片尾，误触发播放完成。
- native seek 如果失败，`time-pos` 不在容差内，仍然会走 service 的 seek。
- `_armInitialPositionGuard` 照常设置，防止之后的旧样本回跳。

测试：续播到 10 分钟、从 0 开始、接近片尾（规范化为 0）、`deferVideo` 路径（它有自己的 native seek），这四种起播情况。

#### A1　外挂音轨健康检查（安全网，阶段 1 之后按日志决定是否需要）

改动：在 native 层检测“时钟在走，但 `audio-pts` 超过 2 秒不动”，或者初始化后收到与音频相关的错误事件，这时在当前位置重新挂载外挂音轨（重新 `audio-add` 同一个 loopback 地址并选中）。每分钟最多触发 2 次；视频轨切换期间以及暂停、缓冲状态下都不触发。

规避：重新挂载本身会造成一次短暂的停顿，所以检测条件要严格，只在确实长时间没有声音时才触发。**阶段 1 解决了音轨提前结束的主要原因（N3/N5/N11）之后再评估是否还需要**，不需要就不做，避免引入新的状态。

#### A2　分轨流跳过专辑封面判定

改动：`player.stream.tracks` 监听中，`externalAudioUri != null` 时不执行 `_disableAlbumArtVideoOutput`。
风险：没有风险（分轨的主文件一定是视频）。

### 阶段 4：“后台播放哔哩哔哩时只加载音频”

前提：阶段 1（特别是 G1）完成之后，这个设置才会真正生效。

#### B1　`deferVideo` 会话的视频传输不做预读

改动：service 通过会话标记“视频不需要预读”，G1 中视频传输的 H 设为 0（只提供 libmpv 真正读取的数据：init、sidx 等少量字节）。进入播放页、启用视频轨时恢复为正常的 H。
验证：通过 O1 的日志，确认在 Mini 播放 10 分钟期间，视频的上游字节数保持在 KB 级别。

#### B2　按视频轨状态切换缓冲参数

改动：禁用视频轨时应用音频档（`demuxer-max-bytes` 等参数，沿用现有 `audioOnly` 的数值）；启用视频轨时恢复视频档。放在同一个 native 命令中执行，保证不会漏掉。

规避：**启用视频轨时忘记恢复视频档，会导致 2MB 缓冲下频繁卡顿**，所以必须和 `vid` 的切换放在同一个函数里，并写测试断言启用后的属性值。

#### B3　“后台”的含义（需要决策，见第 6 节）

建议：开关打开时，应用进入 `hidden` / `paused`（**不包括** `inactive`，避免 Windows 失去焦点、Android 下拉通知栏时来回切换）并持续 1 秒以上，就禁用视频轨；回到前台时启用视频轨，并使用 V1/V2 遮罩。

依赖：必须在 V1、V2、M1 完成之后再做。当初不在后台禁用，正是因为回前台时会黑一下，而这个问题要靠 V1/V2 解决。

#### B4　视频轨策略状态绑定到 controller

改动：`_requestedBilibiliVideoTrackEnabled` 改为记录“对哪个 controller 请求了什么”；controller 更换（清晰度切换、新的 play、预热 controller 接管）时重置。清晰度预热 controller 在没有播放页且开关打开时，同样以 `deferVideo` 方式创建。
效果：解决 N14。

#### 不在本次范围内

`audioPrimary` / `_bilibiliAudioPrimaryPlayer` 这条死代码建议另外单独清理，不和本次修复放在同一个提交里，避免无关的改动掩盖回归问题。

### 附：缓存策略（N7 的另一半）

G2 之后，策略关闭已经不会删除数据，损失变小了。另外建议把策略放宽为：**在线卡片 && (正在播放 || 有前台播放页)**。“正在播放”本身就说明数据正在被消费，桌面最小化时也应该继续缓存。这是一个行为变化，列入第 6 节决策。

---

## 4. 各项修改之间的相互影响

| 修改 | 相关项 | 需要注意 |
|---|---|---|
| G1 背压 | B1、B2 | B1 依赖 G1；H 的大小同时影响卡顿和流量，两者要一起调。 |
| G1 取消上游 | 清晰度切换、切集 | 旧会话会真正停止。确认 `_releasePreviousStreamAfterHandoffFrame` 是在新画面挂上之后才释放旧会话（现在就是这样），避免旧画面还在显示时数据就断了。 |
| G1 | `clearCache` 不关闭会话的约定 | 清缓存只停写，不取消传输。 |
| G2 写穿 | G6 清缓存、Windows 句柄 | 清缓存必须先关闭写入方。 |
| G3 拼接 | G5（需要 `totalBytes`） | G5 要先于 G3 或与 G3 一起上线。 |
| G4 续传 | G1（空闲断连） | G1 上线时必须同时带上 G4。 |
| G7 会话标记 | 清晰度切换、切集、预热 | 所有 `releasePlayback` 的路径都要取消标记。 |
| V1 提前遮罩 | 清晰度切换 | 清晰度切换不走 V1。 |
| V1 | M2 | 遮罩要覆盖到定位完成；M2 减少了定位次数，遮罩时间也会随之缩短。 |
| V2 | M1、V1、B3 | M1、V1、B3 都依赖 V2 的信号。 |
| M1 恢复属性 | Mini 音频打顿问题 | 必须等缓冲足够再恢复。 |
| B3 | V1、V2、M1 | 必须在这三项之后做。 |

---

## 5. 发布顺序与回滚

1. **阶段 0**：只包含观测和测试，可以直接合入。
2. **阶段 1**：G5 + G6 + G8 → G1 + G4 → G2 → G3 → G7。G1–G4 放在 `useGatewayV2` 开关后面，先在 debug 和自己的设备上跑 1～2 天，对比 O1 的日志（活跃传输数、内存、命中率）后再默认打开。回滚时关闭开关即可恢复旧实现。G5 会改变缓存文件名，**开关回退不能恢复旧缓存**，这一点要知晓。
3. **阶段 2**：V2 spike → V1 → V3（N13 确认后）。
4. **阶段 3**：M1、M2、A2；A1 视阶段 1 之后的日志决定。
5. **阶段 4**：B4 → B1 → B2 → B3（需要先决策）。

每个阶段一个或多个独立提交，提交说明写清楚对应解决了第 2 节中的哪个问题编号。

---

## 6. 需要你决定的事项

1. **缓存行为变化（G1）**：修复后只缓存“实际看过的部分 + 少量预读”，不会再因为僵尸下载顺带缓存整个文件。是否接受？（建议接受；需要整片离线使用下载功能）
2. **预读缓冲 H 的大小**：桌面 8MB、移动端 4MB 是否合适？更大的值更抗网络抖动，但更耗流量和内存。
3. **B3 “后台”的定义**：开关打开时，应用切到后台（播放页仍在）是否也只加载音频？（建议是，与设置文案一致；前提是 V1/V2 完成）
4. **缓存策略放宽**：是否改为“正在播放或有前台播放页”就允许缓存（包括桌面最小化）？（建议是）
5. **旧缓存失效（G5）**：升级后每张卡的在线缓存会失效一次，是否接受？

---

## 7. 验证场景

每个阶段完成后，在 Windows 和 Android 上各跑一遍下面的场景；带 ★ 的是本次问题直接相关、必须通过的场景。

| 场景 | 预期 |
|---|---|
| ★ 连续拖动进度条 10 次，再拖回已看过的位置 | 活跃上游传输数不超过 2（视频 + 音频），回到已缓存的位置基本立即出画面，内存不持续上涨 |
| ★ 看 5 分钟，退出，重新进入，拖回第 2 分钟 | 数据全部来自磁盘（O1 日志），不出现 `Stream ends prematurely` |
| ★ 从媒体库进入新的哔哩哔哩卡片（开启/关闭进页自动播放） | 全程是封面 → 画面，不出现黑帧或 t=0 闪一下 |
| ★ Mini 播放中进入播放页（开关开/关） | 无黑帧，音频不打顿 |
| ★ 长时间播放（30 分钟以上），中途切换网络 | 声音不丢；日志里可以看到网关续传（G4） |
| ★ 开启“只加载音频”，Mini 播放 10 分钟 | 视频上游字节数保持在 KB 级别；进入播放页后画面正常，缓冲参数恢复为视频档 |
| 切清晰度（播放 / 暂停） | 无黑帧；旧会话的上游传输在交接后 1 秒内停止 |
| 切上/下一集（页面内、Mini、系统通知） | 正常起播，没有额外的重试 |
| 过夜暂停后切清晰度、切下一集 | 不出现 410，不需要重试 |
| Windows 最小化播放 5 分钟再恢复 | 这段内容被缓存（如果第 6 节第 4 项决定放宽） |
| 播放中清除缓存（单卡 / 全部） | 播放不中断，清除后不出现错误的画面或声音，缓存大小显示正确 |
| 接近片尾的续播点 | 从头开始播放，不会误触发播放完成 |
| 播放中打开倍速/清晰度弹窗 | 视频轨不变，无黑帧 |
