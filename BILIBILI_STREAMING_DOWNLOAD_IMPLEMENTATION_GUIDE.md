# Bilibili 点播流媒体播放与下载：跨语言实现规范

> 文档版本：1.0（基于本仓库 2026-08-28 的代码状态）<br>
> 目标读者：负责在任意语言、任意客户端/服务端框架中重建该能力的开发者或 AI<br>
> 范围：Bilibili 点播视频（UGC、分 P、合集/UGC Season、PGC 番剧）的解析、播放、下载、字幕、章节与弹幕。直播不是本文范围。

## 0. 先读结论

本仓库已经实现了一套不依赖 BBDown 可执行文件的 Dart 版下载链路：输入解析、Cookie/扫码登录、WBI 签名、DASH 取流、清晰度选择、视频多连接 Range 下载、音频续传、备用 CDN、任务持久化、FFmpeg 合并、字幕/章节、弹幕和产物校验均已有实现。

本仓库**没有实现 Bilibili 在线流媒体播放**。新项目应复用“解析与轨道选择”的概念，但不能把当前下载器直接当播放器。推荐的新架构是：

1. 用统一解析核心取得视频、音频及辅助轨道。
2. 用稳定的“逻辑轨道 ID”管理清晰度、编码与续传，不持久化依赖临时 CDN URL。
3. 原生播放器优先直接合并两个媒体源，或播放动态生成的本地 MPD。
4. Web、小程序及不支持请求头/双轨的播放器，经受控的本机或服务端媒体网关播放。
5. 下载与播放共享 API、鉴权、轨道模型、URL 刷新和错误分类；缓存策略、调度器和最终输出逻辑分离。

最重要的约束：Bilibili 的 Web API 和 CDN URL 并非稳定公开协议。接口、风控、清晰度权限和 URL 有效期都可能变化。实现必须可替换、可观测，并对非零业务码、链接过期、Range 不一致和编码不兼容显式处理。

---

## 1. 当前项目实现审计

### 1.1 代码职责地图

| 文件 | 已实现职责 | 新项目复用方式 |
|---|---|---|
| `lib/utils/bilibili_url_parser.dart` | BV、AV、EP、SS、短链和分享文本识别 | 复用输入类型与规范化思路，修正 AV 与域名校验 |
| `lib/services/bilibili/bilibili_api_service.dart` | HTTP 会话、Cookie、扫码登录、WBI、元数据、DASH、字幕、章节、弹幕 | 抽象为无 UI 的 `BilibiliGateway` |
| `lib/services/bilibili/wbi_signer.dart` | WBI mixin key 与 MD5 签名 | 只复用算法轮廓；通用实现须修正 URL 编码与密钥刷新 |
| `lib/models/bilibili_models.dart` | 视频、分 P、合集、DASH 轨道 | 扩充为完整、不可变的标准化领域模型 |
| `lib/models/bilibili_download_task.dart` | 任务、分片、续传、状态机 | 将“逻辑轨道身份”和“临时 URL”拆开 |
| `lib/services/bilibili/download_manager.dart` | 探测、Range 下载、备用 URL、续传、合并、校验、修复 | 下载执行器的主要参考 |
| `lib/services/bilibili/download_integrity.dart` | `Content-Range`、分片规划、长度校验 | 可直接按契约移植 |
| `lib/services/bilibili/media_connection_pool.dart` | 全局 CDN 连接池与可取消等待 | 复用两层限流设计 |
| `lib/services/bilibili/post_process_task_queue.dart` | 合并/修复串行队列与超时 | 复用后处理隔离设计 |
| `lib/services/bilibili/bilibili_download_state_manager.dart` | JSON 快照、临时文件替换、串行写入、重启恢复 | 复用原子持久化原则 |
| `lib/services/bilibili/bilibili_download_service.dart` | 解析任务、选流、队列、重试、清理、导入媒体库 | 参考编排，不与 UI 状态管理绑定 |

### 1.2 当前已经可靠实现的行为

- 一段文本可包含完整链接或 ID；支持多行批量解析。
- 短链先用不跟随重定向的 `HEAD` 解析，再用 `GET` 兜底。
- 普通视频解析为“任务 → 视频 → 分 P”；UGC 合集和番剧解析为多视频任务。
- Cookie 持久化，支持手动设置 `SESSDATA` 和二维码扫码登录。
- `/x/web-interface/nav` 同时用于登录状态和 WBI key 获取。
- `/x/player/wbi/playurl` 使用 `fnval=4048` 获取 DASH 视频/音频轨道。
- 清晰度按质量等级优先、带宽次优排序；音频选择普通音轨中带宽最高者。
- 视频文件可按 Range 分为最多 4 片并发下载；不足 16 MiB/连接时减少连接数。
- 音频使用单连接顺序续传；视频 Range 不可用时回退单连接。
- 所有任务共享一个 CDN 连接池，当前上限 8；同时下载任务数和单视频连接数另有限制。
- 所有媒体请求使用 `Referer: https://www.bilibili.com/`、浏览器 User-Agent、`Accept-Encoding: identity`。
- 依次尝试 `base_url` 和去重后的 `backup_url`；20 秒无数据判定为停滞。
- 严格验证 `206`、`Content-Range`、分片边界、最终字节数；拒绝把错误响应当媒体文件。
- URL 返回 401/403/404 时判定为临时链接失效，重新取流后继续已有字节。
- 下载状态包含逻辑流信息和分片进度；重启后有有效临时文件即可恢复为待继续。
- FFmpeg 串行合并视频、音频、可选字幕和章节，输出 MP4 并启用 `faststart`。
- HEVC 复制封装时写 `hvc1` tag；合并后检查容器、音视频轨道、文件大小和时长。
- 可下载 JSON 字幕并转 SRT，也可把字幕嵌入 MP4；失败时保留外挂字幕。
- 可下载 XML 弹幕并转换为 ASS；弹幕失败不使主视频下载失败。
- 下载阶段结束即释放下载槽，资源较重的合并/修复进入独立串行队列。
- 任务保存采用“内存快照 → 临时文件 → 同目录替换”，并串行化写入，避免旧快照覆盖新顺序。

### 1.3 不应原样移植的问题

这些是新项目必须修正的边界，不代表整个现有功能不可用。

| 问题 | 影响 | 正确处理 |
|---|---|---|
| AV 输入最终把 `av123` 当 `bvid` 传入 | AV 解析可能失败 | 去掉 `av` 前缀，将纯数字作为 `aid`；BV 才传 `bvid` |
| 短链判断使用字符串包含 | 恶意域名可能伪装含 `b23.tv` | 解析 URI 后严格匹配 `b23.tv`、`bili2233.cn` 主机及其允许子域；限制重定向次数和最终域名 |
| WBI 查询串未做完整 RFC 3986 编码 | 含中文、空格或特殊字符的签名会错 | 排序后逐值过滤 `!'()*`，再做 UTF-8 百分号编码；空格为 `%20`，不可为 `+` |
| WBI key 永久缓存在内存 | key 轮换后持续失败 | 设置 TTL；遇签名/风控相关响应时强制刷新一次后重试 |
| 只保存 DASH 的少数字段 | 无法可靠生成 MPD | 保存宽高、帧率、SAR、`start_with_sap`、`segment_base.initialization/index_range`、时长等 |
| 只读取 `dash.audio` | 漏掉杜比音频和 Hi-Res/FLAC | 同时标准化 `dash.audio`、`dolby.audio`、`flac.audio`，并做设备能力判断 |
| 下载时按 `quality id` 再找第一条视频流 | 同清晰度下可能换成另一个编码 | 轨道主键至少包含 `id + codecid + codecs`；切换/恢复必须按完整主键匹配 |
| 最高带宽音频无条件优先 | 设备可能无法解码，或用户并非会员 | 普通 AAC 为安全默认；杜比/FLAC 仅在权限、设备和用户偏好均满足时选择 |
| API 层主要依赖 HTTP 状态 | HTTP 200 但业务 `code != 0` 时错误不清晰 | 每个 API 先验证根对象、业务码和必需字段，再解析数据 |
| UGC 与 PGC 取流未分适配器 | 部分番剧、区域或付费内容可能错误 | 分别实现 UGC 与 PGC resolver；明确预览、会员、付费、区域限制，不绕过授权 |
| 质量名源码中已有乱码字符串 | 显示与按名称推断可能错误 | 质量判断以数值 ID 和服务端字段为准；UI 文案使用 UTF-8 资源文件 |
| 登录凭据使用普通文件 CookieJar | 移动端安全性不足 | Cookie 元数据可普通存储，`SESSDATA`、`bili_jct` 等凭据使用系统安全存储并禁止日志输出 |

---

## 2. 新项目的模块边界

不要让页面、播放器插件或下载库直接调用 Bilibili API。推荐以下语言无关分层：

```text
InputNormalizer
  -> ContentResolver (BV/AV/EP/SS/short-link -> AssetGraph)
  -> AuthSession + WbiSigner
  -> PlayUrlResolver (UGC / PGC)
  -> TrackNormalizer + TrackSelector
       -> PlaybackSession -> PlayerAdapter / MediaGateway
       -> DownloadPlan    -> DownloadExecutor -> Muxer -> Verifier
  -> Subtitle / Chapter / Danmaku adapters
```

核心层不得依赖 Flutter、React Native、WebView、ExoPlayer、AVPlayer 或任何 UI 框架。平台层只实现以下端口：

- `HttpTransport`：重定向、Cookie、流式响应、Range、取消、超时。
- `SecureCredentialStore`：保存敏感 Cookie。
- `PlayerAdapter`：加载双轨、MPD 或渐进式媒体，暴露时钟和错误事件。
- `FileStore`：临时文件、原子替换、可用空间和最终导出。
- `MuxerProbe`：FFmpeg、系统媒体框架或服务端等价实现。
- `TaskStore`：持久化下载计划与续传快照。

### 2.1 必要领域模型

字段名可随语言改变，语义不能丢失。

```text
ContentRef
  inputType: BV | AV | EP | SS
  bvid?: string
  aid?: integer-string
  epId?: integer-string
  seasonId?: integer-string

AssetGraph
  collection?: { id?, title, cover }
  videos[]: { bvid, aid, title, owner, cover, pages[] }
  page: { cid, pageNo, title, durationMs }

VideoTrack
  key: qualityId + codecId + codecString + dynamicRange
  qualityId, qualityLabel
  codecId, codecs, mimeType
  bandwidth, width, height, frameRate, sar
  dynamicRange: SDR | HDR | DolbyVision | unknown
  segmentBase: { initializationRange, indexRange }
  candidates[]: { url, priority }

AudioTrack
  key: audioId + codecs + audioClass + language
  audioId, codecs, mimeType, bandwidth
  audioClass: normal | dolby | hires
  language?, languageLabel?
  segmentBase
  candidates[]

ResolvedMediaSession
  content identity: bvid/aid + cid
  obtainedAt, refreshAfter
  availableQualities[]
  videoTracks[], audioTracks[]
  selectedVideoKey, selectedAudioKey
  durlSegments[]?       # 渐进式兜底，可能不止一段
  entitlement snapshot # 登录/VIP/预览状态，只用于解释结果
```

`url` 是短期解析结果，不是内容身份。数据库、播放历史和下载归档使用 `bvid/aid + cid + 完整轨道 key`。

---

## 3. 鉴权、HTTP 与 WBI

### 3.1 HTTP 会话

API 请求的最低公共头：

```text
User-Agent: 一个固定且真实的浏览器 UA
Referer: https://www.bilibili.com/
Accept: application/json, text/plain, */*
```

媒体请求另加：

```text
Referer: https://www.bilibili.com/
User-Agent: 与解析会话一致
Accept-Encoding: identity
Range: bytes=<start>-<end>   # 按需
```

必须使用同一用户会话解析 API。不要把 Cookie 写进 MPD、URL、错误消息、遥测或下载文件。向 CDN 请求时仅发送实际必要的头；不要把 Bilibili Cookie 转发到非 Bilibili/非既定 CDN 主机。

### 3.2 登录状态与扫码

1. 请求 `/x/web-interface/nav`。
2. 仅当 HTTP 成功、根对象合法且 `data.isLogin` 为布尔值时，判定登录/未登录。
3. 网络错误或结构异常是 `unavailable`，不能误判为退出登录。
4. 二维码：调用 `/x/passport-login/web/qrcode/generate`，展示 `url`，保存 `qrcode_key`。
5. 约每 2 秒调用 `/x/passport-login/web/qrcode/poll?qrcode_key=...`：
   - `0`：成功，完整接收响应中的所有 `Set-Cookie`。
   - `86101`：未扫码。
   - `86090`：已扫码、未确认。
   - `86038`：二维码过期，停止轮询并重新生成。
6. 成功后再次请求 nav 验证，不能只相信 poll 文案。

手动导入 `SESSDATA` 可作为高级入口，但扫码登录必须保留 `SESSDATA` 之外的关联 Cookie。退出登录时清除整个该域 Cookie 集与内存中的 WBI/取流缓存。

### 3.3 WBI 签名契约

1. 从 nav 的 `data.wbi_img.img_url/sub_url` 取文件名（去扩展名），得到 `imgKey/subKey`。
2. 连接 `imgKey + subKey`，按固定的 32 项换位表取字符，再截取 32 位得到 `mixinKey`。
3. 复制业务参数，加入秒级 Unix 时间戳 `wts`。
4. 按参数名升序排序。
5. 每个值先删除字符 `!'()*`，再按 UTF-8 RFC 3986 百分号编码；空格必须是 `%20`。
6. 连接为查询串，尾部拼 `mixinKey`，计算 MD5 得到 `w_rid`。
7. 请求携带业务参数、`wts` 和 `w_rid`。

缓存 key，但设置有限 TTL。首次出现签名相关异常时：清 key → 重新获取 → 重签 → 只重试一次，防止无限循环。

---

## 4. 输入解析与内容树

### 4.1 输入规范化

接受：分享文本、完整 URL、`BV...`、`av...`、`ep...`、`ss...`，大小写可容忍。步骤：

1. 去首尾空白，从分享文案中提取第一个合法 `https` URL 或第一个合法 ID。
2. URL 使用 URI 解析器，不用字符串包含判断域名。
3. 只允许 `bilibili.com` 的既定页面域名，以及短链 `b23.tv`、`bili2233.cn`。
4. 短链最多跟随有限次重定向；每一步只允许 HTTP(S)，最终页面也必须在允许域名内。
5. BV 保留规范化的 `BV` 前缀；AV/EP/SS 去前缀后验证为正整数。
6. 未识别输入返回结构化 `UnsupportedInput`，不继续猜测。

### 4.2 标识符不可混用

- `bvid` / `aid` 标识稿件。
- `cid` 标识稿件中的具体媒体内容；同一多 P 视频每 P 的 `cid` 不同。
- `ep_id` 标识 PGC 单集，`season_id` 标识 PGC 季。
- 播放、字幕、章节、弹幕和下载的最小上下文是 `bvid 或 aid + cid`，仅有 BV/AV 不够定位分 P。

### 4.3 解析流程

**UGC（BV/AV）**

1. 调用视频信息接口；BV 传 `bvid`，AV 传纯数字 `aid`。
2. 根数据生成视频节点，`pages[]` 生成分 P 节点。
3. 若存在 `ugc_season.sections[].episodes[]`，保留 section 层级；每个 episode 仍按自己的 `bvid/aid/cid/pages` 解析。
4. 不要假定合集 episode 永远单 P；缺 `pages` 时才用 episode 的 `cid` 构造单页兜底。

**PGC（EP/SS）**

1. 用 `ep_id` 或 `season_id` 获取 season 数据。
2. 保存每集的 `ep_id、bvid、aid、cid、title、long_title、cover`。
3. PGC 取流由独立 resolver 处理；不要因为返回了 bvid 就无条件走 UGC 取流。
4. 对预览、会员、付费、区域受限分别返回明确错误；不得把权限限制伪装成网络故障或静默降质。

---

## 5. 取流与轨道标准化

### 5.1 UGC DASH 请求

使用 WBI 签名调用 `/x/player/wbi/playurl`，典型参数：

```text
bvid=<BV...> 或 aid=<纯数字>
cid=<整数>
qn=0
fnval=4048
fnver=0
fourk=1
try_look=1   # 仅匿名会话按需使用；视服务策略调整
```

`fnval=4048` 请求所有可用 DASH 能力。DASH 响应中 `qn` 不应被当作唯一筛选器，真实可用轨道以响应数组为准。每次响应必须验证：HTTP 成功、业务 `code == 0`、存在合法 `data`，并识别 `dash` 或 `durl`。

PGC 使用对应的 PGC Web playurl adapter，并标准化成同一轨道模型。接口差异只应停留在 gateway 内部。

### 5.2 必须读取的 DASH 字段

- 根：`timelength`，`accept_quality[]`，`accept_description[]`，`dash.duration`。
- 视频：`id`、`base_url/baseUrl`、`backup_url/backupUrl`、`bandwidth`、`mime_type/mimeType`、`codecs`、`codecid`、`width`、`height`、`frame_rate/frameRate`、`sar`、`start_with_sap`、`segment_base/SegmentBase`。
- 普通音频：`dash.audio[]`。
- 杜比音频：`dash.dolby.audio[]` 或响应中的等价位置。
- Hi-Res：`dash.flac.audio` 或响应中的等价位置。
- `SegmentBase`：兼容 snake_case/camelCase 的 `initialization` 与 `index_range/indexRange`。

主 URL 为空时用第一条有效 backup；候选列表按原始优先级去重。协议相对 URL `//...` 统一补为 `https:`。

### 5.3 质量与编码是两个维度

常见质量 ID：`16=360P`、`32=480P`、`64=720P`、`74=720P60`、`80=1080P`、`112=1080P+`、`116=1080P60`、`120=4K`、`125=HDR`、`126=Dolby Vision`、`127=8K`。常见视频 `codecid`：`7=AVC`、`12=HEVC`、`13=AV1`。

不要仅按数字大小或带宽选择。推荐选择算法：

1. 过滤 URL、MIME、初始化范围不合法的轨道。
2. 过滤账户当前不可用的轨道；以响应实际返回为准，不凭设置页推断会员权限。
3. 按用户清晰度上限选择最高可用层；若该层不存在，向下回退。
4. 同一质量内，根据平台运行时能力选择编码：明确支持 AV1/HEVC 才选，否则 AVC。
5. HDR/Dolby Vision 还需显示链路、系统 API 和播放器均支持；不支持则回退 SDR，而不是只换 codec。
6. 最后才用带宽决定同类轨道优先级。
7. 音频默认选兼容性最高的普通 AAC；杜比或 FLAC 必须是显式偏好且运行时探测通过。

必须保留“用户请求的质量”和“实际选择的轨道”，便于解释降级原因。

---

## 6. 在线流媒体播放设计（本仓库尚未实现）

### 6.1 播放器接入的优先顺序

**方案 A：播放器原生支持分离音视频源**

向同一播放时间线加入选中的视频 URL 和音频 URL，并为两者设置媒体请求头。这是最直接的实现。例如支持合并媒体源的播放器可将两个 progressive/MP4 source 合为一个 timeline。播放器必须负责时间戳同步、共同 seek 和统一缓冲状态。

**方案 B：生成静态 DASH MPD**

当播放器支持 DASH 但不接受两个独立 URL 时，根据一次 playurl 响应生成 MPD：

- `type="static"`，时长来自 `dash.duration`，不可写虚假的固定时长。
- 一个视频 `AdaptationSet` 和一个音频 `AdaptationSet`。
- 每个选中轨道成为 `Representation`，写真实 MIME、codec、bandwidth、宽高和帧率。
- `BaseURL` 指向该轨道稳定的网关 URL，而不是直接长期缓存 CDN URL。
- `SegmentBase indexRange="..."` 和 `<Initialization range="..."/>` 必须来自对应轨道。
- XML 属性和 URL 必须转义。

初版推荐一个 MPD 只放一个固定视频质量和一个固定音频轨道。若要 ABR，只把已验证时间轴对齐、动态范围一致且播放器支持的 Representations 放入同一 AdaptationSet；切换 codec/HDR 档不应盲目交给自动 ABR。

**方案 C：渐进式 MP4 兜底**

另行请求 MP4/html5 格式的 `durl`。它通常清晰度更低，但兼容性最好。`durl[]` 可能多段，必须按 `order` 顺序拼接时间线；不能只播放第一段。该方案适用于不支持 DASH/MSE、初始化失败或双轨不兼容的平台。

不要为在线播放预先下载完整视频并合并；那不是流媒体播放。

### 6.2 受控媒体网关

Web、小程序、部分 WebView 和部分原生播放器无法可靠添加 Referer、跨域请求或在 MPD 分片请求中刷新 URL。推荐提供稳定网关：

```text
GET /media/<unguessable-session>/<track>/manifest.mpd
GET /media/<unguessable-session>/<track>/bytes
```

网关职责：

- 仅接受服务器已解析并登记的 session/track；绝不能成为任意 URL 代理。
- 原生本地网关只绑定 loopback；服务端网关必须鉴权、限流、隔离用户。
- 上游主机来自当前解析结果且需 HTTPS/主机 allowlist 校验，防止 SSRF。
- 流式转发请求体，不把整个视频读入内存。
- 透传合法 `Range`，并原样保留 `206`、`Content-Range`、`Content-Length`、`Accept-Ranges`、内容类型。
- 向 Bilibili CDN 注入所需 Referer/UA；不向客户端暴露 Cookie。
- 当前 URL 失败时依次尝试 backup；401/403/404 或明确过期信号触发一次重新取流。
- 重取流后按完整逻辑轨道 key 匹配新 URL，并对同一 Range 重试；找不到相同轨道才向播放器报告“轨道已不可用”。
- 客户端取消/seek 后立即取消无用的上游请求。

### 6.3 URL 生命周期

CDN URL 是临时、可能与会话/IP相关的能力凭证。不要把它当永久资源，不要跨设备同步，不要作为收藏地址。社区资料记录的典型有效期约 120 分钟，但实现不应假定所有 URL 都严格相同。

推荐策略：

- `ResolvedMediaSession` 只作短缓存；保守地在取得后约 90 分钟标为需刷新。
- 播放前若已过 `refreshAfter`，先重新解析。
- 播放中遇 401/403/404、连续 Range 失败或播放器明确源错误时刷新一次。
- 同一错误最多做一次“刷新并恢复”，随后降级 codec/质量或 durl，避免死循环。
- URL 刷新不改变用户的内容身份、播放位置、字幕选择和弹幕时间线。

### 6.4 播放状态机

```text
idle -> resolving -> preparing -> ready <-> playing/paused
                         |          |
                         |          -> seeking / switchingQuality
                         -> recovering -> preparing
                         -> failed
```

关键行为：

- 每次加载分配 generation/session ID；旧异步请求完成后不得覆盖新视频状态。
- `ready` 前显示封面；首帧或播放器已渲染事件后再隐藏。
- seek 以媒体时钟为准；拖动期间取消低优先级预取，松手后发一次最终 seek。
- 切清晰度：记录 `position + paused/rate` → 选新轨道/必要时刷新 URL → 替换 source → 等待 ready → seek 回原位置 → 恢复状态。
- 自动恢复同样保存位置；只有在播放器报告错误且网关刷新失败后才降级。
- 音视频缓冲取交集；任一必需轨道未就绪都不应显示为可连续播放。
- 后台/前台、音频焦点、中断和网络切换由平台适配器处理，核心只接收事件。

### 6.5 字幕、章节与弹幕

- 用 `/x/player/wbi/v2` 获取 `subtitle.subtitles[]` 与 `view_points[]`。
- 字幕 URL 可能是 `//...`；标准化为 HTTPS。JSON 字幕可转 WebVTT/SRT 或交给自定义渲染层。
- 字幕轨道身份用 `id + lan + type/isAi`，不要只按显示名称恢复。
- 章节保存 `from/to/content`，正规化为不重叠、位于媒体时长内的区间。
- 本项目已支持 `comment.bilibili.com/<cid>.xml` → ASS。新播放器可沿用 XML 兼容路径；若遇长视频数据不全，再增加分段弹幕协议适配器。
- 在线弹幕和字幕必须读取播放器媒体时钟；暂停、seek、倍速和缓冲时不能依赖系统墙钟累加。
- seek 后清除屏幕上旧弹幕，按新时间窗口重建；渲染层不能阻塞解码线程。

---

## 7. 下载实现规范

### 7.1 从选择到下载计划

用户确认下载时冻结以下内容：

- `bvid/aid + cid`、标题和输出命名信息。
- 请求质量上限与实际视频完整轨道 key。
- 实际音频完整轨道 key。
- 字幕轨道 key、是否下载弹幕、章节快照。
- 唯一 `artifactKey`，用于所有临时文件和安全清理。

URL 可以放在运行时状态中帮助快速恢复，但不能作为唯一轨道身份。开始任务或 URL 失效时重新取流，并用完整 key 找新候选 URL。

### 7.2 单轨下载算法

1. 建立候选列表：主 URL 在前，backup URL 在后，去空和去重。
2. 使用 HEAD 探测总长度；失败后可请求 `Range: bytes=0-0` 并立即取消响应体。探测失败不能阻止全新顺序下载。
3. 始终用 `Accept-Encoding: identity`，否则字节 Range 与压缩后的长度可能不一致。
4. 已有连续文件时请求 `Range: bytes=<existing>-`。
5. 只有收到 `206` 且 `Content-Range.start == existing` 才允许追加。
6. 服务端忽略 Range 返回 `200` 时，删除/隔离旧临时文件，从 0 重下，禁止把完整响应追加到旧文件。
7. `416` 仅在本地字节数等于已知总长时可视为完成；否则清理不可信状态并重启该轨道。
8. 响应结束后，若已知总长，必须严格等于总长；未知总长也必须大于 0。
9. 401/403/404 触发 URL 刷新；408/412/416/429、5xx、超时、连接断开和停滞可有限重试。
10. 尊重 `Retry-After`，并加指数退避和少量随机抖动；暂停/取消须能中断等待。

### 7.3 视频多连接 Range

当前项目的可复用策略：

- 连接数 `min(用户设置, 4, floor(totalBytes / 16MiB))`，至少 1。
- 生成覆盖 `[0, totalBytes-1]`、首尾相接且不重叠的闭区间。
- 每片独立临时文件和 `downloadedBytes`；恢复时验证文件长度与状态一致。
- 每个请求必须精确匹配请求的 start/end/total，响应块不得越界。
- 失败先切换同轨 backup URL；并发错误时可从 4 → 2 → 1 降低。
- CDN 不支持严格 Range 时删除分片计划，回退顺序续传。
- 所有分片完成后按序写入 `.assembling` 文件，验证总长，再原子替换逻辑轨道文件。

当前项目仅对视频多连接，音频顺序下载。这是合理默认：音频较小，额外连接收益低。未来若让音频也并发，必须复用相同完整性规则，不能另写宽松路径。

### 7.4 两层并发与阶段隔离

- **任务并发**：同时下载多少个 episode，移动端默认 1，桌面端可按资源调整。
- **连接并发**：所有任务共享 CDN 连接池，防止 `任务数 × 分片数` 失控。
- **后处理并发**：合并和兼容性修复独立队列；低内存设备建议串行。

视频和音频下载完成后释放“下载任务槽”，再进入后处理队列。否则慢速 FFmpeg 会长期占住网络队列。

### 7.5 续传快照

每个轨道至少保存：

```text
tempPath
logicalTrackKey
lastResolvedUrl?          # 提速用，可失效
downloadedBytes
totalBytes?
supportsRange
rangeParts[] { start, endInclusive, downloadedBytes, tempPath }
resumeSchemaVersion
```

恢复前逐项验证：路径必须位于应用临时目录；文件存在；长度与快照一致；分片连续覆盖；轨道 key 与当前选择一致。任一关键条件不成立就安全废弃该轨道的续传状态，不能“尽量拼起来”。

运行中每次进度都可更新内存，但磁盘持久化需要节流；暂停、错误、退出和状态阶段变化时强制刷盘。写入使用临时文件和原子替换，并串行化保存操作。

### 7.6 合并、字幕和章节

下载完成后先用 probe 验证视频分片确有视频轨、音频分片确有音频轨，再开始 mux。

等价 FFmpeg 逻辑：

```text
input 0 = video.m4s
input 1 = audio.m4s
input 2 = optional subtitle.srt
last input = optional ffmetadata chapters
video codec = copy
audio codec = copy
HEVC output tag = hvc1（需要兼容目标平台时）
subtitle codec in MP4 = mov_text
map_chapters = chapter input
movflags = +faststart
output = staging-output.mp4
```

注意：

- “MP4 封装”不等于“所有设备都能解码”。复制 HEVC/AV1 仍要求设备支持相应 codec。
- 默认先无损封装；仅在播放器实际兼容性探测失败时，进入明确、可取消、有限时的转码修复。
- 字幕嵌入失败可重试无字幕合并并保留外挂 SRT，不能让可选字幕毁掉主媒体。
- 章节元数据中的换行、反斜杠、`=`、`;`、`#` 必须按 ffmetadata 规则转义。
- 后处理需有超时、进程终止和 stdout/stderr 排空机制，避免子进程死锁。

### 7.7 最终校验与提交

只有同时满足以下条件才标记完成：

- 输出文件存在且大小合理。
- 容器 probe 成功。
- 至少一条视频轨和一条音频轨。
- 输出时长与源视频/音频时长在预设容差内。
- 目标目录有足够空间，最终移动/复制成功。

最终文件先写 staging 名，校验后再提交到目标路径。跨卷移动不具备原子性时使用“复制到目标 staging → flush → 校验 → rename”。成功后才能删除源分片；失败必须保留可续传输入。

### 7.8 错误分类

| 类别 | 例子 | 行为 |
|---|---|---|
| 用户动作 | pause/cancel | 立即停止请求/等待/进程，保留可信续传状态，不计失败 |
| 临时网络 | timeout、reset、408、5xx | 有界退避重试，保留进度 |
| 风控/限流 | 412、429 | 尊重 Retry-After，降低并发，避免紧密重试 |
| URL 失效 | 401、403、404 | 重新取流并按完整轨道 key 续传 |
| Range 不兼容 | 返回 200、错误 Content-Range | 重启单轨或降级单连接，不追加错误数据 |
| 数据完整性 | 长度、边界、probe、时长不符 | 停止并明确报错；不提交输出 |
| 权限/内容 | 未登录、会员、付费、区域、下架 | 不自动重试；展示真实原因 |
| 后处理 | mux/repair 失败或超时 | 保留下载分片，可单独重试后处理 |

---

## 8. 多端落地策略

| 运行环境 | 推荐播放 | 推荐下载 | 关键限制 |
|---|---|---|---|
| Android | Media3/等价播放器：MPD 或合并媒体源；本地 loopback 网关 | 原生后台任务 + Range + FFmpeg/Media3 Transformer | 编码、HDR、后台限制和存储权限需运行时探测 |
| iOS/macOS | 支持组合资产的播放器，或将 DASH 经受控网关转换为平台可接受输入 | 原生 URLSession/后台任务；mux 可本地或服务端 | iOS 对任意 MPEG-DASH 的原生支持不应想当然；准备 HLS/MP4 或服务端兜底 |
| Windows/Linux 桌面 | libmpv/FFmpeg/GStreamer 或支持 DASH 的引擎 | 本地 Range + FFmpeg 最完整 | 注意硬解 codec 与软件解码功耗差异 |
| Web/PWA | Shaka Player/dash.js + 同源媒体网关 | 浏览器小文件可下载；大文件与合并推荐服务端 | CORS、禁止自定义 Referer、内存和后台生命周期 |
| 小程序 | 平台原生 video 支持的 MP4/HLS；通常经服务端网关 | 服务端异步下载/合并，再给临时授权地址 | 请求域名白名单、文件 API、后台和 FFmpeg 能力受限 |

因此，大项目应允许同一核心输出三种播放描述：`SeparateTracks`、`DashManifest`、`ProgressiveSegments`。平台适配器声明能力，核心按能力选择，而不是在业务代码里判断框架名称。

若使用服务端网关：用户 Cookie 必须逐用户加密隔离；更推荐客户端解析后将短时、受限的媒体会话交给网关。任何设计都不得提供绕过会员、付费、地域或版权限制的功能。

---

## 9. 推荐实施顺序

1. 建立无 UI 的领域模型、错误类型、HTTP/Cookie/WBI 层。
2. 完成严格的 BV/AV/EP/SS/短链解析和 AssetGraph。
3. 实现 UGC playurl、完整 DASH 字段解析、复合轨道 key 和能力驱动选流。
4. 移植当前下载完整性、续传、备用 URL、全局连接池和持久化契约。
5. 接入 probe/mux，完成事务式提交；随后接字幕、章节和弹幕。
6. 实现 `PlaybackSession` 与平台 `PlayerAdapter`，先固定质量双轨/单 Representation MPD。
7. 增加受控媒体网关、URL 热刷新、切清晰度恢复和渐进式兜底。
8. 最后再做 ABR、杜比、Hi-Res、HDR、AV1、后台下载和跨端同步。

不要先做 UI。先让同一组 API fixture 在所有语言实现中产生相同的 AssetGraph、轨道排序和错误分类。

---

## 10. 测试矩阵与验收条件

### 10.1 解析和权限

- BV、大小写 BV、纯 AV、链接 AV、EP、SS、短链、分享文案、多行输入、非法域名。
- 单 P、多 P、UGC 合集多 section、合集内多 P、完整番剧季。
- 匿名、普通登录、会员；下架、预览、付费、区域受限分别断言错误。
- WBI 使用含中文、空格、`!'()*` 和非 ASCII 参数的固定测试向量。
- nav 网络失败不得清除登录状态；扫码四种状态与多 `Set-Cookie` 正确处理。

### 10.2 轨道和播放

- 同质量 AVC/HEVC/AV1 共存时，复合 key 与兼容性选择正确。
- SDR/HDR/Dolby Vision 不混选；普通/Dolby/FLAC 音频按能力回退。
- MPD 使用真实时长、SegmentBase、转义后的 URL；音视频 seek 后同步。
- 首播、暂停、倍速、前后 seek、切质量、切前后台、断网恢复。
- 模拟 URL 过期：刷新后保持轨道、位置和暂停状态；刷新失败只降级一次。
- 主 URL 失败使用 backup；所有候选失败后错误可解释。
- Web/小程序通过网关 Range 播放；网关拒绝任意外部 URL 与越权 session。

### 10.3 下载和完整性

- 服务器支持 Range、忽略 Range、返回错误 start/end/total、提前结束、超量返回、未知总长。
- HEAD 失败但 GET 成功；`0-0` 被忽略时立即取消响应体。
- 单连接与 2/4 连接结果哈希一致；并发失败能降为 2/1。
- 任务暂停时可能正处于连接池等待、重试等待、网络读、合并或修复，各阶段均可终止。
- 杀进程后恢复单文件和多 Range 分片；快照与文件不一致时安全废弃。
- URL 刷新后同 codec 续传；找不到原轨道时禁止把不同编码拼到旧文件。
- 字幕/弹幕失败不影响主媒体；mux 失败保留输入；最终输出不完整绝不标记完成。
- 低磁盘空间、重名、非法文件名、跨卷提交和临时目录清理。
- 500+ 任务下持久化顺序不回退、UI/事件流不因每个网络块全量重算。

### 10.4 完成定义

一个平台只有同时满足以下条件才算完成：

- 能从至少 BV、AV、EP、SS 和短链定位具体 `cid`。
- 能播放分离 DASH 音视频，支持 seek、暂停和 URL 过期恢复。
- 能明确展示实际质量/codec 与降级原因。
- 能可靠暂停、重启续传，并通过 Range 和最终媒体完整性测试。
- 不记录或泄露 Cookie、签名参数、完整临时媒体 URL。
- 权限错误不会被重试风暴掩盖，也不会尝试绕过授权。

---

## 11. 供未来 AI 使用的实现约束

未来生成代码时必须遵守：

1. 先实现本文的接口契约和测试，再适配 UI 框架。
2. 不硬编码“第一条视频/第一条音频就是最佳”；必须走轨道选择器。
3. 不用质量 ID 单独标识视频轨；必须包含 codec/dynamic range。
4. 不持久化依赖 CDN URL；恢复时允许重新解析并映射逻辑轨道。
5. 不在内存中读取完整媒体，不用普通 HTTP GET 覆盖已有断点文件。
6. 不信任 HTTP 200；同时验证 Bilibili 业务码、响应结构和媒体完整性。
7. 不假设播放器自动携带 Referer/Cookie，也不假设所有平台原生支持 MPEG-DASH。
8. 不把 MPD 的 `SegmentBase` 写成猜测值，不写伪造时长。
9. 不把网络错误判定为退出登录，不在日志输出 Cookie 或完整签名 URL。
10. 不扩大到直播协议；直播 HLS/FLV/WebSocket 弹幕需要另一份设计。

---

## 12. 参考资料与稳定性说明

以下资料用于核对接口字段和播放设计；Bilibili 相关资料多为社区逆向文档，不是平台稳定性承诺：

- [BBDown 原项目](https://github.com/nilaoda/BBDown)：解析、下载、FFmpeg/MP4Box 合并与多编码能力参考。
- [BBDown-rust 用户指南](https://github.com/Joey-Project/BBDown-rust/blob/master/docs/user-guide.zh-CN.md)：DASH 轨道、Range 续传、`Content-Range`/大小校验、章节合并等近期实现参考。
- [bilibili-api-collect 镜像：视频流 URL](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/videostream_url.md)：playurl 参数、质量 ID、codec ID、DASH/SegmentBase、杜比与 FLAC 字段。
- [bilibili-api-collect 镜像：WBI 签名](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/misc/sign/wbi.md)：key 获取、换位、RFC 3986 编码和 MD5 签名。
- [bilibili-api-collect 镜像：播放器信息](https://github.com/bilibili-plugins/bilibili-api-collect/blob/master/docs/video/player.md)：字幕与章节字段。原 `SocialSisterYi/bilibili-API-collect` 地址现已不可用，因此这里使用可访问镜像；其内容仍属社区逆向资料。
- [JKVideo](https://github.com/tiajinsha/JKVideo)：Bilibili DASH 响应生成本地 MPD并交给原生播放器的开源案例。该项目仓库已声明停止维护，代码仅用于验证思路，不应直接依赖。
- [BiliTV for webOS](https://github.com/asdf17128/bili-webos)：Shaka Player、设备内 HTTP 媒体/API 代理和 DASH 播放的跨端案例。
- [Android Media3 DASH 文档](https://developer.android.com/media/media3/exoplayer/dash)：分离音视频 AdaptationSet 和 DASH 播放能力。
- [Android Media3 MergingMediaSource](https://developer.android.com/reference/androidx/media3/exoplayer/source/MergingMediaSource)：原生合并多媒体源的参考抽象。
- [W3C Media Source Extensions](https://www.w3.org/TR/media-source-2/)：Web 端音视频 SourceBuffer、缓冲、seek 与自适应流的标准基础。

实施时应把上述 API endpoint、字段别名、错误码和 WBI 行为集中在可替换 adapter 中。任何生产发布前都要用当前账号类型和目标网络重新做契约测试。
