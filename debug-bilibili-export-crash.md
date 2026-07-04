# Debug Session: bilibili-export-crash
- **Status**: [OPEN]
- **Issue**: Windows 下批量下载哔哩哔哩视频时，在“下载完成 -> 导出到媒体库”阶段历史上出现过闪退；当前日志显示导出成功，但伴随无障碍树错误与 `media_kit` 纹理频繁重建。
- **Debug Server**: http://127.0.0.1:7777/event
- **Log File**: `.dbg/trae-debug-log-bilibili-export-crash.ndjson`

## Reproduction Steps
1. 在 Windows 版本中批量添加多个哔哩哔哩下载任务。
2. 开启自动导出到媒体库。
3. 在任务进入“已合成/正在导出”阶段时观察应用是否卡顿、闪退，或播放器页是否出现纹理重建。

## Hypotheses & Verification
| ID | Hypothesis | Likelihood | Effort | Evidence |
|----|------------|------------|--------|----------|
| A | 导出成功后 `library.addSingleVideo()` 或其后续通知触发了页面级联重建，导致 `media_kit` 纹理被频繁销毁/重建，进而引发 Flutter Windows 无障碍树异常 | High | Med | Pending |
| B | 顺序导出泵与下载页/播放页共享状态，`notifyListeners()` 过于频繁，导出中途触发无障碍树更新竞争，历史闪退发生在该竞争窗口 | High | Low | Pending |
| C | 导出阶段虽然已改为分块复制，但缩略图生成或字幕复制仍在主线程同步执行，导致长时间阻塞并放大 Windows 桌面端稳定性问题 | Med | Med | Pending |
| D | 某些导入后自动生成缩略图的路径会隐式创建视频播放器实例，批量导出时与播放页现有播放器争抢原生纹理/句柄 | High | Med | Pending |
| E | 日志中的 `accessibility_bridge.cc` 错误是历史闪退前兆，真实根因在 Flutter Windows 语义树节点失配，被高频页面重建放大 | Med | Med | Pending |

## Log Evidence
- 用户提供的日志显示跨盘 `rename` 失败后，分块复制与最终导出均成功。
- 同一时间窗口内反复出现 `Failed to update ui::AXTree, error: 36 will not be in the tree and is not the new root`。
- 导出成功后立即出现 `media_kit` 纹理创建、释放与 `VideoOutput::~VideoOutput`，存在原生视频输出频繁重建迹象。
- 已添加 `pre-fix` 插桩，覆盖 `importToLibrary()`、`library.addSingleVideo()`、`MediaDurationProbe` 的 VideoPlayer 回退路径与缩略图生成结束点。

## Verification Conclusion
Pending instrumentation and runtime evidence.
