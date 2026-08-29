# Bilibili 点播流媒体播放与下载实现教程

> 适用范围：小程序、Web、手机应用、桌面应用及服务端；不限定语言和框架。<br>
> 本文只描述实现逻辑、模块契约和验收标准，不提供某种语言的完整代码。<br>
> 本文讨论点播视频。直播的取流、WebSocket 弹幕和时移播放是另一套协议，不在本文范围内。

## 1. 目标与基本原则

需要实现的完整能力包括：

- 识别 BV、AV、EP、SS、Bilibili 页面链接、短链接和分享文案。
- 解析单视频、多分 P、UGC 合集和 PGC 番剧。
- 支持匿名及登录取流，并正确处理普通用户、会员、付费、预览和区域限制。
- 播放 Bilibili DASH 分离音视频流，支持暂停、seek、清晰度切换和临时 URL 刷新。
- 下载视频、音频、字幕、章节和可选弹幕，支持暂停、断点续传、备用 CDN 和完整性校验。
- 在下载后无损合并音视频，必要时处理字幕、章节和编码兼容性。
- 为不同平台输出适合的播放方式，而不把业务核心绑定到播放器框架。

实现时遵守以下原则：

1. **内容身份与媒体 URL 分离。** `bvid/aid + cid + 轨道标识` 是稳定身份；CDN URL 只是短期凭证。
2. **清晰度与编码分离。** 1080P 可能同时有 AVC、HEVC、AV1，不能只用质量 ID 标识轨道。
3. **解析、播放和下载共享核心。** 三者共享登录会话、WBI、内容模型、取流和选轨；播放器与下载器各自维护缓存和状态机。
4. **不信任 HTTP 200。** 同时验证 Bilibili 业务码、JSON 结构、Range 响应和最终媒体。
5. **所有重试有界。** URL 刷新、备用地址、网络重试和质量降级都必须限制次数，避免循环。
6. **权限限制不是网络故障。** 未登录、会员、付费、区域限制和内容下架必须作为确定性结果返回。

---

## 2. 推荐架构

```text
输入
  -> InputNormalizer
  -> ContentResolver
  -> AssetGraph
  -> PlayUrlResolver
  -> TrackNormalizer
  -> TrackSelector
       ├─> PlaybackSession -> PlayerAdapter / MediaGateway
       └─> DownloadPlan    -> DownloadExecutor -> Muxer -> Verifier

公共基础设施：
AuthSession | CookieStore | WbiSigner | HttpTransport | TaskStore | Telemetry
```

### 2.1 模块职责

| 模块 | 单一职责 |
|---|---|
| `InputNormalizer` | 从用户输入中提取并规范化 BV、AV、EP、SS 或合法链接 |
| `ContentResolver` | 将输入解析为视频、合集、番剧和分 P 内容树 |
| `AuthSession` | 管理 Cookie、扫码登录、登录状态和安全存储 |
| `WbiSigner` | 获取动态 key、缓存、签名和失效刷新 |
| `PlayUrlResolver` | 分别处理 UGC 与 PGC 取流，并返回原始播放响应 |
| `TrackNormalizer` | 把字段别名和不同音轨位置统一成标准轨道模型 |
| `TrackSelector` | 根据用户偏好、权限和设备能力选择实际音视频轨道 |
| `PlaybackSession` | 管理播放源、位置、质量切换、URL 刷新和恢复 |
| `MediaGateway` | 为不能直接请求 CDN 的播放器代理 MPD、Range 和请求头 |
| `DownloadExecutor` | 分片、续传、备用 URL、限流、重试和临时文件 |
| `Muxer` | 合并音视频、字幕和章节 |
| `Verifier` | 校验长度、容器、轨道、时长和最终产物 |

核心模块只能依赖抽象接口，不依赖 UI、播放器控件或特定文件选择器。

### 2.2 平台必须提供的适配接口

- `HttpTransport`：Cookie、重定向、流式响应、Range、取消和超时。
- `SecureCredentialStore`：安全保存敏感 Cookie。
- `PlayerAdapter`：加载双轨、MPD 或渐进式媒体，并暴露媒体时钟和错误事件。
- `FileStore`：临时文件、剩余空间、原子替换和最终导出。
- `MuxerProbe`：FFmpeg、系统媒体 API 或服务端等价能力。
- `TaskStore`：保存任务、轨道选择和续传状态。

---

## 3. 统一数据模型

字段名可以改变，但语义不能丢失。

### 3.1 内容模型

```text
ContentRef
  type: BV | AV | EP | SS
  bvid?: string
  aid?: integer-string
  epId?: integer-string
  seasonId?: integer-string

AssetGraph
  collection?:
    id?: string
    title: string
    coverUrl: string
    sections[]
  videos[]:
    bvid: string
    aid: integer-string
    title: string
    owner?: { mid, name }
    coverUrl: string
    pages[]:
      cid: integer
      pageNo: integer
      title: string
      durationMs: integer
    pgc?: { epId, seasonId }
```

### 3.2 视频轨道

```text
VideoTrack
  key: qualityId + codecId + codecs + dynamicRange
  qualityId: integer
  qualityLabel: string
  codecId: integer
  codecs: string
  mimeType: string
  bandwidth: integer
  width: integer
  height: integer
  frameRate: string
  sar?: string
  startWithSap?: integer
  dynamicRange: SDR | HDR | DOLBY_VISION | UNKNOWN
  segmentBase:
    initializationRange: "start-end"
    indexRange: "start-end"
  candidates[]:
    url: string
    priority: integer
```

### 3.3 音频轨道

```text
AudioTrack
  key: audioId + codecs + audioClass + language
  audioId: integer
  codecs: string
  mimeType: string
  bandwidth: integer
  audioClass: NORMAL | DOLBY | HI_RES
  language?: string
  languageLabel?: string
  segmentBase
  candidates[]
```

### 3.4 解析会话

```text
ResolvedMediaSession
  contentKey: bvid/aid + cid
  obtainedAt: timestamp
  refreshAfter: timestamp
  requestedQuality: preference
  videoTracks[]
  audioTracks[]
  selectedVideoKey
  selectedAudioKey
  progressiveSegments[]?  # durl 兜底；必须保留全部分段及顺序
  entitlement:
    loggedIn
    vip
    previewOnly
    restrictionReason?
```

数据库、收藏、播放历史和下载归档不得以 CDN URL 作为主键。

---

## 4. HTTP、Cookie 与登录

### 4.1 公共请求头

API 请求至少保持一致的浏览器会话信息：

```text
User-Agent: 固定且真实的浏览器 UA
Referer: https://www.bilibili.com/
Accept: application/json, text/plain, */*
```

媒体请求使用：

```text
User-Agent: 与解析会话一致
Referer: https://www.bilibili.com/
Accept-Encoding: identity
Range: bytes=<start>-<end>  # 按需
```

`Accept-Encoding: identity` 对下载完整性很重要，否则内容编码可能使 Range 和长度含义发生变化。

### 4.2 登录状态

调用：

```text
GET https://api.bilibili.com/x/web-interface/nav
```

只有在以下条件全部成立时才更新登录状态：

- HTTP 请求成功。
- 返回根对象和 `data` 结构合法。
- `data.isLogin` 是明确的布尔值。

结果分为：

- `LOGGED_IN`：明确已登录。
- `LOGGED_OUT`：明确未登录。
- `UNAVAILABLE`：网络失败、HTTP 异常或结构异常。

`UNAVAILABLE` 不能导致客户端删除 Cookie或显示“登录过期”。

### 4.3 二维码登录

1. 请求 `/x/passport-login/web/qrcode/generate`。
2. 展示返回的二维码 URL，并保存 `qrcode_key`。
3. 约每 2 秒请求 `/x/passport-login/web/qrcode/poll?qrcode_key=...`。
4. 处理状态：

| code | 含义 | 行为 |
|---:|---|---|
| `0` | 登录成功 | 接收响应中全部 `Set-Cookie`，停止轮询 |
| `86101` | 未扫码 | 继续轮询 |
| `86090` | 已扫码、未确认 | 继续轮询并更新提示 |
| `86038` | 二维码过期 | 停止轮询，要求重新生成 |

5. 登录成功后再次请求 nav 验证，不只依赖 poll 的提示文字。

扫码登录必须保留完整关联 Cookie。手动输入 `SESSDATA` 只能作为高级兼容入口，不能代替完整登录流程。

### 4.4 凭据安全

- `SESSDATA`、`bili_jct` 等敏感 Cookie 使用系统安全存储。
- 日志、崩溃报告和遥测不得包含 Cookie、完整媒体 URL、二维码登录 URL或完整请求查询串。
- 退出登录时清除该用户的全部 Cookie、WBI 缓存和媒体会话缓存。
- 多账号必须使用完全隔离的 CookieJar、任务和缓存命名空间。

---

## 5. WBI 签名

### 5.1 获取动态 key

从 nav 响应的以下字段获取 URL：

```text
data.wbi_img.img_url
data.wbi_img.sub_url
```

分别取 URL 文件名并去掉扩展名，得到 `imgKey` 和 `subKey`。无需下载对应图片。

### 5.2 生成 mixinKey

连接 `imgKey + subKey`，按以下索引顺序取字符，拼接后截取前 32 位：

```text
46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,
27,43,5,49,33,9,42,19,29,28,14,39,12,38,41,13
```

### 5.3 生成签名

1. 复制业务参数。
2. 加入当前秒级 Unix 时间戳 `wts`。
3. 按参数名升序排序。
4. 每个值先删除 `!'()*`。
5. 对键和值做 UTF-8 RFC 3986 百分号编码；空格必须编码为 `%20`，不能编码为 `+`。
6. 连接为查询串，在末尾直接拼接 `mixinKey`。
7. 对整个字符串计算 MD5，小写十六进制结果为 `w_rid`。
8. 请求携带原业务参数、`wts` 和 `w_rid`。

### 5.4 缓存与刷新

- WBI key 可缓存，但必须设置有限 TTL。
- 遇到签名异常、`v_voucher` 或相关结构异常时，只允许执行一次：清缓存 → 重新获取 key → 重签 → 重试。
- 第二次失败直接返回错误，不能无限刷新。
- 签名使用的时钟应能检测设备时间严重错误；必要时提示用户校准系统时间。

---

## 6. 输入解析与内容树

### 6.1 支持的输入

- `BV...`
- `av...`
- `ep...`
- `ss...`
- Bilibili 视频或番剧页面 URL
- `b23.tv`、`bili2233.cn` 短链
- 包含以上内容的分享文案

### 6.2 规范化流程

1. 去除首尾空白。
2. 从分享文案提取第一个合法 HTTPS URL；没有 URL 时提取第一个合法 ID。
3. URL 必须使用标准 URI 解析器解析，不能通过字符串包含判断域名。
4. 严格允许 Bilibili 页面域名以及 `b23.tv`、`bili2233.cn` 短链域名。
5. 短链只允许有限次 HTTP(S) 重定向，每一步和最终 URL 都做协议及域名校验。
6. BV 规范为大写 `BV` 前缀；AV、EP、SS 去掉前缀后必须是正整数。
7. 无法识别时返回 `UNSUPPORTED_INPUT`，不要继续猜测。

### 6.3 标识符语义

- `bvid` 和 `aid` 标识同一个稿件的两种 ID。
- `cid` 标识稿件内具体媒体内容；多分 P 的每一 P 都有独立 `cid`。
- `ep_id` 标识 PGC 单集。
- `season_id` 标识 PGC 季。
- 播放、字幕、章节、弹幕和下载的最低定位信息是 `bvid 或 aid + cid`。

### 6.4 UGC 解析

UGC 元数据通常通过以下接口获取；若当前接口策略要求 WBI，则由 gateway 切换到对应的 `/wbi/view` 变体并签名：

```text
GET https://api.bilibili.com/x/web-interface/view
```

1. BV 使用 `bvid` 请求视频信息。
2. AV 去掉 `av` 前缀，将纯数字作为 `aid`，不能把 `av123` 填入 `bvid` 参数。
3. 用根数据建立视频节点，用 `pages[]` 建立分 P 节点。
4. 若包含 `ugc_season.sections[]`，保留 section 层级并遍历所有 episode。
5. 每个合集 episode 使用自己的 `bvid/aid/cid/pages`。
6. 不假定合集 episode 一定是单 P；只有缺失 `pages` 时才用 episode 的 `cid` 构建单页兜底。

### 6.5 PGC 解析

PGC season 元数据通常通过以下接口获取：

```text
GET https://api.bilibili.com/pgc/view/web/season
```

1. EP 使用 `ep_id`，SS 使用 `season_id` 请求 season 数据。
2. 保存每集的 `ep_id、season_id、bvid、aid、cid、title、long_title、cover`。
3. PGC 与 UGC 使用独立取流适配器，再标准化为相同轨道模型。
4. 明确区分预览、会员、付费、区域受限、内容下架和网络失败。
5. 不实现任何绕过会员、付费或区域授权的行为。

---

## 7. 取流与响应标准化

### 7.1 UGC DASH 取流

使用 WBI 签名调用：

```text
GET https://api.bilibili.com/x/player/wbi/playurl
```

典型业务参数：

```text
bvid=<BV...> 或 aid=<纯数字>
cid=<整数>
qn=0
fnval=4048
fnver=0
fourk=1
try_look=1  # 仅匿名会话按当前接口策略决定是否添加
```

`fnval=4048` 用于请求所有可用 DASH 能力。DASH 模式下不能只根据请求中的 `qn` 判断结果；实际可用质量以响应轨道为准。

### 7.2 PGC 取流

PGC 通过独立的 PGC Web playurl 适配器解析。不同时间可能存在 `/pgc/player/web/playurl`、Web v2 或等价变体，因此：

- 端点和参数只存在于 PGC gateway 内。
- 业务层只接收标准化轨道或结构化限制错误。
- 仅在接口明确表示端点兼容问题时尝试已验证的备用端点。
- 会员、付费、区域限制不能触发匿名绕过或非授权代理。

### 7.3 响应验证

解析任何取流响应前依次验证：

1. HTTP 状态是否成功。
2. 根对象是否为 JSON 对象。
3. 业务 `code` 是否为 `0`。
4. `data` 或 PGC 等价数据对象是否存在。
5. 是否包含可用 `dash` 或 `durl`。
6. 是否存在至少一个可播放视频轨道；音频缺失时要明确标记为无音频内容或异常。

业务错误应映射为统一错误类型，保留原始 code 供诊断，但 UI 不直接显示未经处理的服务端文本。

### 7.4 必须读取的字段

根与 DASH：

- `timelength`
- `accept_quality[]`
- `accept_description[]`
- `dash.duration`

视频轨道：

- `id`
- `base_url` / `baseUrl`
- `backup_url` / `backupUrl`
- `bandwidth`
- `mime_type` / `mimeType`
- `codecs`
- `codecid`
- `width`、`height`
- `frame_rate` / `frameRate`
- `sar`
- `start_with_sap` / `startWithSap`
- `segment_base` / `SegmentBase`

音频来源：

- 普通音频：`dash.audio[]`
- 杜比音频：`dash.dolby.audio[]` 或响应中的等价位置
- Hi-Res：`dash.flac.audio` 或响应中的等价位置

`SegmentBase` 同时兼容：

- `initialization`
- `index_range` / `indexRange`

URL 处理规则：

- `//host/path` 补为 `https://host/path`。
- 主 URL 为空时使用第一条有效 backup。
- 候选 URL 按主 URL、backup 原始顺序去重。
- URL 主机必须经过 HTTPS 和允许域校验。

---

## 8. 轨道选择

### 8.1 常见视频质量

| ID | 质量 |
|---:|---|
| `6` | 240P，通常仅渐进式 MP4 |
| `16` | 360P |
| `32` | 480P |
| `64` | 720P |
| `74` | 720P60 |
| `80` | 1080P |
| `112` | 1080P+ 高码率 |
| `116` | 1080P60 |
| `120` | 4K |
| `125` | HDR |
| `126` | Dolby Vision |
| `127` | 8K |

常见 `codecid`：`7=AVC/H.264`、`12=HEVC/H.265`、`13=AV1`。

质量 ID 不能简单按整数大小排序，因为 HDR、Dolby Vision、高帧率和分辨率不是同一维度。应建立明确的质量优先级表。

### 8.2 视频选择算法

1. 丢弃 URL、MIME、codec 或 SegmentBase 明显不合法的轨道。
2. 以服务端实际返回为权限事实，不凭本地会员设置伪造可用轨道。
3. 根据用户的清晰度上限找到最高可用质量；不存在时向下回退。
4. 同质量内根据运行时能力选择 codec：只有明确支持时才选 AV1/HEVC，否则优先 AVC。
5. HDR/Dolby Vision 需要解码器、显示链路、操作系统和播放器全部支持；否则回退 SDR。
6. 在质量、codec 和动态范围相同后，再按带宽或服务端顺序选择。
7. 保存请求质量、实际轨道和降级原因。

运行时能力必须通过平台 API 或播放器探测获得，不能只按操作系统名称推断。

### 8.3 音频选择算法

1. 默认选择兼容性最好的普通音轨，通常为 AAC 系列中可用的较高码率。
2. Dolby 只有在账户有权、设备支持且用户明确开启时选择。
3. Hi-Res/FLAC 只有在播放器、输出链路和用户偏好均满足时选择。
4. 多语言音频先按用户语言匹配，再比较音频类型和码率。
5. 恢复旧选择时使用完整音频 key，不只使用码率或数组下标。

---

## 9. 在线流媒体播放

### 9.1 播放接入优先级

#### 方式 A：原生合并分离音视频源

如果播放器支持把独立视频 URL 和音频 URL 合并到同一时间线：

- 分别建立视频源和音频源。
- 两个源使用一致的必要请求头。
- 交由播放器根据媒体时间戳同步。
- seek、暂停、缓冲和错误作为一个播放会话处理。

这是原生平台最直接的方案。

#### 方式 B：动态生成静态 DASH MPD

如果播放器支持 DASH 但只接受一个 manifest：

```xml
MPD(type=static, mediaPresentationDuration=真实时长)
  Period
    AdaptationSet(video MIME/codec)
      Representation(真实 bandwidth/width/height/frameRate)
        BaseURL(稳定网关视频地址)
        SegmentBase(indexRange=视频 indexRange)
          Initialization(range=视频 initializationRange)
    AdaptationSet(audio MIME/codec)
      Representation(真实 bandwidth)
        BaseURL(稳定网关音频地址)
        SegmentBase(indexRange=音频 indexRange)
          Initialization(range=音频 initializationRange)
```

必须遵守：

- MPD 时长来自本次响应，不能写固定假值。
- 视频和音频使用各自的 SegmentBase，不能共用或猜测。
- XML 属性和 BaseURL 必须转义。
- 初版每个 MPD 只放一个固定视频质量和一个音频轨道。
- 只有确认时间轴对齐、动态范围一致且播放器支持时，才加入多个 Representation 做 ABR。
- MPD 缓存键至少包含内容、cid、视频 key、音频 key 和会话 generation。

#### 方式 C：渐进式 MP4 兜底

对不支持 DASH、MSE 或双轨播放的平台，另行请求 MP4/html5 `durl`：

- 该方式通常质量较低，但兼容性更好。
- `durl[]` 可能包含多段，必须按 `order` 依次组成播放列表。
- 不能只播放第一段。
- DASH 初始化失败、codec 不支持或平台限制明确时才降级。

在线播放不应先下载完整音视频再合并；这不属于流媒体播放。

### 9.2 媒体网关

Web、小程序、部分 WebView 或播放器可能无法添加 Referer、跨域请求、可靠透传 Range 或刷新 MPD 内的 CDN URL。这些平台使用本机或服务端媒体网关。

建议接口：

```text
GET /media/<unguessable-session>/manifest.mpd
GET /media/<unguessable-session>/video
GET /media/<unguessable-session>/audio
```

网关必须：

- 只代理已解析并登记的 session/track，禁止传入任意 URL。
- 本机网关只绑定 loopback；服务端网关必须鉴权、限流并隔离用户。
- 只允许当前解析结果中的 HTTPS 上游主机，防止 SSRF。
- 流式转发，不把完整媒体读入内存或磁盘后再响应。
- 透传合法 Range 请求。
- 保留 `206`、`Content-Range`、`Content-Length`、`Accept-Ranges`、`Content-Type`。
- 向上游注入必要 Referer/UA，但不向客户端暴露 Cookie。
- 主 URL 失败后按顺序尝试 backup URL。
- 401/403/404 或明确过期时重新取流，并按完整轨道 key 找到新 URL。
- 找到新 URL 后对相同 Range 重试；找不到同一轨道时返回明确错误。
- 客户端取消、seek 或切清晰度时立即取消不再需要的上游请求。

### 9.3 临时 URL 生命周期

CDN URL 不能跨设备同步或长期保存。社区资料记录的典型有效期约 120 分钟，但实现不得假定所有链接都严格一致。

推荐：

- 解析会话使用短缓存，可在获取后约 90 分钟标记为需刷新。
- 播放开始前若超过 `refreshAfter`，先重新解析。
- 播放中遇 401/403/404、连续 Range 失败或播放器源错误时刷新一次。
- 刷新后用完整视频/音频 key 映射新 URL，不改变播放位置和用户选择。
- 同一故障只允许一次刷新恢复；随后按 codec、质量、durl 顺序有限降级。
- 不依赖解析 URL 内某个查询参数推断所有 CDN 的统一过期时间。

### 9.4 播放状态机

```text
IDLE
  -> RESOLVING
  -> PREPARING
  -> READY
  -> PLAYING <-> PAUSED
  -> SEEKING
  -> SWITCHING_QUALITY
  -> RECOVERING
  -> FAILED / ENDED
```

状态约束：

- 每次加载分配新的 generation ID；旧请求完成后不得覆盖新会话。
- 首帧或播放器已渲染事件发生后再隐藏封面。
- seek 使用播放器媒体时钟；拖动结束时只提交一次最终 seek。
- 音视频缓冲区按交集判断可播放，不能只看视频缓冲。
- 恢复操作保存 `position、paused、rate`，重新准备后再还原。
- 网络切换、前后台、音频焦点和系统中断由平台适配层转换为统一事件。

### 9.5 清晰度切换

1. 保存当前媒体位置、播放/暂停状态和倍速。
2. 从现有 session 选择目标轨道；session 过期则先重新取流。
3. 构建新的双轨源或 MPD。
4. 增加 generation，替换播放器 source。
5. 等待新 source 进入可 seek 的 ready 状态。
6. seek 回原位置。
7. 恢复暂停状态和倍速。
8. 超时或失败时回到旧轨道；旧 URL 已失效则进入恢复/降级流程。

不要在新 source 尚未 ready 时立即 seek，也不要使用旧加载事件关闭新会话的 loading 状态。

---

## 10. 字幕、章节与弹幕

### 10.1 播放器元数据

使用 WBI 签名的播放器信息接口获取：

```text
GET https://api.bilibili.com/x/player/wbi/v2
```

携带 `bvid 或 aid + cid`，读取：

- `data.subtitle.subtitles[]`
- `data.view_points[]`

### 10.2 字幕

- 字段至少保存 `id、lan、lan_doc、subtitle_url、is_lock、ai_type/ai_status`。
- `//...` URL 补为 HTTPS。
- 字幕身份使用 `id + lan + AI/type`，不能只用显示名或数组下标。
- JSON 字幕可以转换为 WebVTT/SRT，或由自定义层直接渲染。
- 下载时字幕是可选资产；字幕失败不能使主媒体失败。
- 切换字幕或恢复任务时按稳定身份匹配，不按旧 URL 匹配。

### 10.3 章节

- 保存 `from、to、content`，统一转换为毫秒或统一时间单位。
- 排序并裁剪到媒体时长范围。
- 丢弃负时间、空区间和明显重叠的无效数据。
- 播放器用章节标记进度条；下载合并时转换为容器章节元数据。

### 10.4 弹幕

兼容入口：

```text
GET https://comment.bilibili.com/<cid>.xml
```

- 响应可能有 gzip/deflate；按响应头或魔数解压，再做 UTF-8 和 XML 结构校验。
- 可转换为 ASS 作为下载旁路文件。
- 长视频若 XML 数据不完整，再增加分段弹幕协议适配器，不改变上层弹幕模型。
- 在线弹幕必须由播放器媒体时钟驱动。
- 暂停和缓冲时停止推进；倍速时自然跟随媒体时钟。
- seek 后清除旧弹幕，并从新位置时间窗口重新调度。
- 渲染和解析不能阻塞视频解码线程。

---

## 11. 下载计划与状态机

### 11.1 冻结下载计划

用户确认下载时保存：

- `bvid/aid + cid`。
- 标题、分 P 序号和安全输出名。
- 请求质量和实际视频完整轨道 key。
- 实际音频完整轨道 key。
- 字幕轨道 key、章节快照、是否下载弹幕。
- 唯一 `artifactKey`。

URL 只作为当前运行时候选。任务开始或 URL 过期时重新取流，并用完整轨道 key 映射新候选。

### 11.2 状态机

```text
PENDING -> RESOLVING -> QUEUED -> DOWNLOADING
  DOWNLOADING 包含独立的 videoState 与 audioState
  两条必需轨道都完成 -> MERGING -> VERIFYING -> COMPLETED

任意可取消阶段 -> PAUSED
可恢复错误 -> RETRY_WAIT -> 原阶段
确定性错误 -> FAILED
```

实现可以并行下载音视频，但进度、暂停和完整性必须按轨道分别保存。`COMPLETED` 只表示最终输出已校验并成功提交。

---

## 12. 媒体下载算法

### 12.1 候选 URL

1. 主 URL 在前，backup URL 在后。
2. 去除空 URL 和重复 URL。
3. 每次请求前验证协议和主机。
4. 单个候选失败后才尝试下一个；成功接收有效数据后不同时从多个 CDN 混写同一顺序文件。
5. Range 分片可以分别切换候选，但每个响应都必须通过严格 Content-Range 校验。

### 12.2 探测总长度

1. 先尝试 HEAD。
2. HEAD 失败或缺长度时，请求 `Range: bytes=0-0`。
3. 读取响应头后立即取消响应体，防止服务器忽略 Range 并返回整个大文件。
4. 从 `Content-Range: bytes 0-0/total` 优先取得总长度。
5. 探测失败不能阻止全新的顺序下载；总长度允许暂时未知。

### 12.3 顺序下载与续传

1. 临时文件不存在时从 0 开始。
2. 临时文件已有 `N` 字节时请求 `Range: bytes=N-`。
3. 只有响应为 `206` 且 `Content-Range.start == N` 才允许追加。
4. 如果服务器忽略 Range 返回 `200`，关闭响应，隔离或删除旧临时文件，再从 0 写入。
5. 收到 `416`：只有 `N == 已知总长` 时可视为已完成，否则清理不可信断点并重启该轨道。
6. 每个响应块写入前检查取消状态。
7. 流在规定时间内没有任何字节则判定停滞，保存可信进度并重试。
8. 结束后验证实际字节数：已知总长时必须严格相等，未知总长时必须大于 0。

### 12.4 视频多连接 Range

推荐默认策略：

```text
connectionCount = min(
  userLimit,
  4,
  floor(totalBytes / 16MiB)
)
最低为 1
```

规则：

- 分片使用闭区间 `[start, endInclusive]`。
- 所有分片必须首尾相接、无空洞、无重叠，并覆盖 `[0, totalBytes-1]`。
- 每片使用独立临时文件，记录真实 `downloadedBytes`。
- 请求必须收到 `206`。
- `Content-Range` 的 start、end 和 total 必须与请求完全一致。
- 响应字节不得超过该分片剩余长度。
- 主 URL 失败可使用 backup URL 继续同一分片。
- 并发错误或限流时按 `4 -> 2 -> 1` 降低连接数。
- CDN 不支持严格 Range 时废弃多片计划，回退顺序续传。

全部分片完成后：

1. 再次验证每个分片的状态和实际文件长度。
2. 按 start 顺序写入单独的 `.assembling` 文件。
3. 验证 assembling 文件长度等于 total。
4. 原子替换为完整轨道临时文件。
5. 成功后删除分片文件。

音频通常较小，默认使用单连接续传即可。若也启用多连接，必须复用完全相同的完整性规则。

### 12.5 URL 过期后续传

401、403、404 或明确 URL 过期错误发生时：

1. 保留已经通过校验的本地字节和分片状态。
2. 重新调用 playurl。
3. 使用原完整视频/音频 key 查找新轨道。
4. 找到后替换候选 URL，继续原 Range。
5. 找不到相同轨道时停止续传，并要求用户确认降级或从头下载新轨道。

绝不能把不同 codec、动态范围或音频类型的数据追加到旧临时文件。

### 12.6 网络重试

可重试：连接/接收/发送超时、连接重置、408、412、429、5xx、流停滞和有限的 416 恢复。

不可自动重试：未登录、会员、付费、区域限制、内容下架、参数错误、轨道消失、磁盘空间不足和确定的完整性失败。

退避策略：

- 读取并尊重 `Retry-After`，但设置合理上限。
- 否则使用如 1、2、4 秒的指数退避并增加少量随机抖动。
- 412/429 时降低并发。
- 暂停/取消必须能立即打断退避等待。
- 每层重试次数独立但有界，避免“URL × 分片 × 任务”形成重试风暴。

---

## 13. 并发、续传状态与持久化

### 13.1 三层调度

- **任务并发**：同时下载多少个分 P/episode。
- **连接并发**：所有任务共享的 CDN 连接池上限。
- **后处理并发**：合并、probe 和转码修复的独立队列。

下载阶段结束后释放网络任务槽，再进入后处理队列。低内存设备通常应串行合并和修复。

连接池等待必须可取消；暂停一个正在等待连接的任务时，不能让它继续占队列或永久挂起。

### 13.2 续传快照

每个轨道保存：

```text
tempPath
logicalTrackKey
lastResolvedUrl?          # 仅作提速提示
downloadedBytes
totalBytes?
supportsRange
rangeParts[]:
  start
  endInclusive
  downloadedBytes
  tempPath
resumeSchemaVersion
```

恢复前验证：

- 临时路径位于应用自己的临时目录。
- 文件存在且实际长度与快照一致。
- 分片计划连续、无重叠并完整覆盖总长。
- 每片下载量在合法区间内。
- 轨道 key 与任务选择一致。
- schema 版本可迁移。

任一关键条件不成立就安全废弃对应轨道的续传状态，不尝试拼接可疑数据。

### 13.3 持久化

- 高频进度只更新内存；定时节流写盘。
- 暂停、错误、阶段切换、应用退出时强制刷盘。
- 先生成不可变快照，再序列化。
- 写入同目录临时文件，flush 后原子替换正式状态文件。
- 所有保存操作串行，防止较旧快照晚完成并覆盖新状态。
- 重启后把 `DOWNLOADING/MERGING/VERIFYING` 修正为 `PAUSED` 或 `FAILED`，不能假装仍在运行。

---

## 14. 合并、校验与最终提交

### 14.1 合并前验证

- 视频临时文件存在、非空，probe 能发现视频轨。
- 音频临时文件存在、非空，probe 能发现音频轨。
- 文件长度与已知总长度相等。
- 目标位置有足够空间，同时考虑临时输出和跨卷复制。

### 14.2 合并逻辑

等价 FFmpeg 逻辑：

```text
input 0 = video.m4s
input 1 = audio.m4s
input 2 = optional subtitle.srt
last input = optional ffmetadata chapters

video codec = copy
audio codec = copy
HEVC MP4 tag = hvc1（目标平台需要时）
subtitle codec = mov_text
map_chapters = chapter metadata input
movflags = +faststart
output = staging-output.mp4
```

规则：

- 默认先无损封装，避免耗时和画质损失。
- MP4 是容器，不代表设备一定能解码其中的 HEVC/AV1。
- 只有播放器兼容性探测实际失败时才进入可取消、有超时的转码修复。
- 字幕嵌入失败时可无字幕重新合并并保留外挂 SRT。
- 章节文本中的换行、反斜杠、`= ; #` 等按 ffmetadata 规则转义。
- 后处理进程必须排空 stdout/stderr，并支持取消、超时和强制终止。

### 14.3 合并后校验

完成必须同时满足：

- 输出文件存在且大小合理。
- 容器 probe 成功。
- 至少包含一条视频轨和一条音频轨。
- 输出时长与源视频/音频时长在预设容差内。
- 需要兼容性检查的 codec 能被目标播放器实际打开。
- 最终文件已成功提交到目标目录。

### 14.4 事务式提交

1. 始终写 staging 输出。
2. 对 staging 执行完整校验。
3. 同卷时原子 rename 到最终路径。
4. 跨卷时：复制到目标 staging → flush → 校验 → rename。
5. 成功提交后再删除音视频分片。
6. 提交失败时保留可信输入，以便只重试后处理。

---

## 15. 统一错误分类

| 类型 | 示例 | 默认行为 |
|---|---|---|
| `USER_CANCELLED` | 暂停、取消 | 立即停止并保留可信续传，不记为失败 |
| `NETWORK_TRANSIENT` | 超时、reset、408、5xx | 有界退避重试 |
| `RATE_LIMITED` | 412、429 | 尊重 Retry-After，降低并发 |
| `MEDIA_URL_EXPIRED` | CDN 阶段的 401、403、404 | 重取流并按完整轨道 key 续传 |
| `RANGE_UNSUPPORTED` | Range 返回 200 | 从头或降级单连接，禁止错误追加 |
| `INTEGRITY_FAILED` | Content-Range、长度、probe、时长错误 | 停止，不提交输出 |
| `AUTH_REQUIRED` | 未登录 | 提示登录，不自动重试 |
| `ENTITLEMENT_REQUIRED` | 会员、付费 | 展示限制，不绕过 |
| `REGION_RESTRICTED` | 区域限制 | 展示限制，不使用未授权代理 |
| `CONTENT_UNAVAILABLE` | 下架、审核、不可见 | 停止并展示原因 |
| `CODEC_UNSUPPORTED` | HEVC/AV1/Dolby 不支持 | 选择兼容轨道或渐进式兜底 |
| `POST_PROCESS_FAILED` | mux/probe/repair 失败 | 保留输入，允许单独重试后处理 |
| `STORAGE_FAILED` | 空间不足、权限、跨卷失败 | 停止写入并保留可恢复状态 |

所有错误包含：稳定错误类型、阶段、是否可重试、公开提示和脱敏诊断信息。不要让 UI 根据异常字符串做业务判断。

---

## 16. 多端实现策略

| 环境 | 播放建议 | 下载建议 | 主要限制 |
|---|---|---|---|
| Android | 支持 DASH 的原生播放器；MPD 或合并媒体源 | 后台任务 + Range + 本地 mux | codec/HDR、后台和存储权限需运行时探测 |
| iOS/macOS | 组合媒体源或平台支持的 HLS/MP4；必要时媒体网关 | 系统后台传输；本地或服务端 mux | 不假定任意 MPEG-DASH 都能被系统播放器直接播放 |
| Windows/Linux | libmpv、FFmpeg、GStreamer 或等价 DASH 引擎 | 本地 Range + FFmpeg | 注意硬解能力、功耗和打包体积 |
| Web/PWA | Shaka Player/dash.js + 同源媒体网关 | 大文件下载和 mux 推荐服务端 | CORS、自定义 Referer、内存与后台生命周期 |
| 小程序 | 平台 video 支持的 MP4/HLS，经服务端网关 | 服务端异步下载/合并 | 域名白名单、文件系统、后台和 FFmpeg 能力有限 |

核心层应输出三种播放描述：

```text
SeparateTracks(video, audio)
DashManifest(manifestUrl)
ProgressiveSegments(segments[])
```

平台适配器声明能力，核心选择最优描述。不要在业务层硬编码某个框架名称。

服务端网关必须逐用户隔离 Cookie 和媒体会话。若需要跨端同步，只同步内容 ID、播放位置、用户偏好和下载任务元数据，不同步 CDN URL。

---

## 17. 推荐实施顺序

1. 建立统一模型、错误类型和平台抽象接口。
2. 实现 Cookie 会话、登录状态、扫码登录和 WBI 签名测试向量。
3. 实现严格输入解析，以及 UGC/PGC 内容树。
4. 实现 UGC 与 PGC 取流 adapter、字段别名和完整轨道标准化。
5. 实现复合轨道 key、能力探测和确定性选轨。
6. 先完成单连接下载、续传、URL 刷新和完整性校验。
7. 增加全局连接池和视频多 Range 下载。
8. 接入 mux、probe、事务式提交、字幕和章节。
9. 实现固定质量的在线双轨或单 Representation MPD 播放。
10. 增加媒体网关、清晰度切换和 URL 热刷新。
11. 接入弹幕、播放历史、后台任务和跨端同步。
12. 最后再做 ABR、HDR、Dolby Vision、Dolby Audio、Hi-Res 和 AV1 优化。

先完成核心契约测试，再开发 UI。不同语言实现应对同一组脱敏 API fixtures 产生相同的内容树、轨道列表、选轨结果和错误类型。

---

## 18. 测试与验收

### 18.1 输入与解析

- BV、大小写 BV、纯 AV、AV URL、EP、SS、短链和分享文案。
- 非法域名、伪装包含 `b23.tv` 的 URL、重定向循环和非 HTTPS 跳转。
- 单 P、多 P、UGC 合集多 section、合集内多 P、完整番剧季。
- `bvid/aid/cid/ep_id/season_id` 不发生混用。

### 18.2 鉴权与 WBI

- 匿名、普通登录和会员响应。
- nav 网络失败不被识别为退出登录。
- 二维码四种状态及多个 `Set-Cookie`。
- WBI 固定测试向量包含中文、空格、非 ASCII 和 `!'()*`。
- key 失效只刷新重试一次。
- 日志中不存在 Cookie、二维码 URL 和完整媒体 URL。

### 18.3 轨道选择

- 同质量 AVC、HEVC、AV1 共存。
- SDR、HDR、Dolby Vision 不发生错误混选。
- 普通、Dolby、FLAC 音频按设备能力和用户偏好回退。
- 服务端没有请求质量时能选择正确的较低质量。
- 恢复和 URL 刷新按完整轨道 key 匹配。

### 18.4 在线播放

- MPD 使用真实时长、真实 SegmentBase 和转义 URL。
- 音视频首播同步，长时间播放不产生明显漂移。
- 暂停、倍速、前后 seek、清晰度切换和首帧状态正确。
- 主 URL 失败后使用 backup。
- 模拟 URL 过期后保持播放位置、暂停状态和倍速。
- 刷新失败只执行有限降级，不循环重载。
- Web/小程序网关正确转发 Range，并拒绝任意 URL 和越权 session。

### 18.5 下载

- HEAD 失败但 GET 成功。
- Range 被支持、被忽略、start/end/total 错误、提前结束、返回过量数据和未知总长。
- 1、2、4 连接结果完全一致。
- 并发失败后降为 2/1，且文件不损坏。
- 主 CDN 和备用 CDN 切换。
- 暂停发生在连接池等待、退避等待、网络读取、合并和校验阶段。
- 杀进程后恢复顺序文件及多个 Range 分片。
- URL 刷新后同轨续传；不同 codec 不允许拼接。
- 字幕或弹幕失败不影响主媒体。
- mux 失败保留输入；不完整输出永不标记完成。
- 低磁盘空间、重名、非法文件名、跨卷提交和临时目录清理。
- 大量任务下状态写入顺序不回退。

### 18.6 完成标准

一个平台同时满足以下条件才算实现完成：

- 能从 BV、AV、EP、SS 和短链定位具体 cid。
- 能播放分离 DASH 音视频，并支持 seek、暂停、质量切换和 URL 过期恢复。
- 能显示请求质量、实际质量、codec 和降级原因。
- 能暂停、重启续传，并通过 Range 和最终媒体完整性测试。
- 权限限制不会被当成网络错误重试。
- Cookie 和短期媒体凭证不会被日志、同步或暴露给非必要组件。
- 下载完成只在最终文件校验并提交成功后发生。

---

## 19. 供代码生成 AI 遵守的硬性约束

1. 先实现领域模型、接口契约和测试，再连接 UI。
2. 不使用 CDN URL 作为内容或轨道主键。
3. 不用质量 ID 单独标识视频轨道。
4. 不假定数组第一项是最佳视频或音频。
5. 不假定所有平台原生支持 MPEG-DASH、HEVC、AV1、HDR 或 Dolby。
6. 不猜测 MPD 的 SegmentBase 和媒体时长。
7. 不把完整媒体读入内存，不把大文件 Range 探测响应读完。
8. 不在收到 `200` 时追加到已有断点文件。
9. 不在 Content-Range 或长度校验失败后继续合并。
10. 不把网络失败解释为退出登录。
11. 不在日志中输出 Cookie、二维码登录 URL 或完整 CDN URL。
12. 不让可选字幕、章节或弹幕失败破坏主媒体。
13. 不用错误字符串驱动状态机；使用稳定错误类型。
14. 不执行无限重试或无限 URL 刷新。
15. 不实现绕过会员、付费、地域或版权限制的逻辑。
16. 不把直播协议混入点播模块。

---

## 20. 参考资料

Bilibili 相关接口属于社区整理的非官方协议，可能变化。实现时应将 endpoint、字段别名、业务码和签名规则集中在可替换 adapter 中。

- [BBDown](https://github.com/nilaoda/BBDown)：Bilibili 解析、下载、多编码和合并流程参考。
- [BBDown-rust 用户指南](https://github.com/Joey-Project/BBDown-rust/blob/master/docs/user-guide.zh-CN.md)：轨道模型、Range 续传、完整性校验和章节合并参考。
- [bilibili-api-collect 镜像：视频流 URL](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/videostream_url.md)：playurl、质量、codec、DASH、SegmentBase、Dolby 和 FLAC 字段。
- [bilibili-api-collect 镜像：WBI 签名](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/misc/sign/wbi.md)：WBI key、换位、编码和 MD5 规则。
- [bilibili-api-collect 镜像：播放器信息](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/player.md)：字幕和章节字段。
- [Android Media3 DASH](https://developer.android.com/media/media3/exoplayer/dash)：分离音视频 AdaptationSet 和 DASH 播放。
- [Android Media3 MergingMediaSource](https://developer.android.com/reference/androidx/media3/exoplayer/source/MergingMediaSource)：合并多个媒体源的参考抽象。
- [W3C Media Source Extensions](https://www.w3.org/TR/media-source-2/)：Web 音视频缓冲、seek 和自适应播放基础。

正式发布前，应使用当前接口、目标地区网络、各账号类型和所有目标平台重新执行契约测试。
