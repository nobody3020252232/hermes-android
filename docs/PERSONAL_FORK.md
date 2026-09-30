# 个人定制版记录（Personal fork）

本仓库是 [rusty4444/hermes-android](https://github.com/rusty4444/hermes-android) 的 fork（`nobody3020252232/hermes-android`），**仅供本人自用**的定制版。

- 每次 push 到 `main` 自动构建 APK：Actions → **Personal APK** → 最新 run → artifact `hermes-personal-apk-*`。
- APK 用个人签名密钥（repo secrets `PERSONAL_*`）签名，可原地覆盖升级本轮及以后的所有版本。
- 首次安装前需卸载官方签名的原版 Hermes（签名不同，安卓不允许直接覆盖安装）。
- 本地签名材料备份在 Mac 的 `~/hermes-signing/`。

## 改动逐轮记录

### R1 — 2026-09-30
- 聊天底部输入栏瘦身：右侧按钮 48dp→40dp；移除"朗读回复"（音量）开关；输入框可视宽度增加。
- 移除会话页顶部与输入框上方重复的一栏（模型 / 思考强度 / 项目 / 连接状态）；连接异常时在标题栏右侧显示 10dp 圆点（橙=重连中、红=离线），正常时不显示。
- 同步更新测试：`test/chat_history_scroll_test.dart`（移除 "Spoken replies"、尺寸断言 48→40）。
- 新增 CI：`Personal APK` workflow（每轮 push 自动出 APK）。

### R2 — 2026-09-30（ask-user-question / clarify 修复）
- 实现 server→client requests（桌面网关链路，此前完全缺失）：连接后声明 `client.capabilities {server_requests: true}`；分发 `srq-…` 请求帧；clarify 弹窗应答（单问=响应帧 `{answer}`；批量=`clarify.lock`）；处理 `request.cancel`（撤回时静默关闭弹窗）；重连时回放 resume 携带的 `open_requests`。
- 其他方法（approval/sudo/secret/vault 等）暂时以 -32601 快速拒绝：行为与之前一致（不发送、不挂起），后续轮次再接。
- 新增测试：`test/gateway_server_requests_test.dart`（真实本地 WS 假网关，覆盖声明、分发、应答、批量锁、重连回放）。
- 范围说明：仅对"桌面网关（dashboard WS）"连接生效；API server（8642）连接模式下后端本身没有 clarify 通道，不在本轮范围。

### R7 — 2026-10-01（手机端不再显示工具调用卡片）
- 起因：实测确认"工具名列表"在手机上是纯噪音——`~/.hermes/state.db` 里 tool 行占全部消息的 **56%**，一个会话产出上百张卡片，其中 **63% 只有一次工具调用**；而历史上这些行只显示"名字 + Completed"（app 的 `_extractToolMessages` 丢掉服务端已下发的 `context`/`args`）。真正有信息的只有失败的调用（约 4%）。
- 改动（方案C）：`buildChatDisplayItems` 现在**只输出失败的工具**：一组工具里若有失败，只渲染失败行；全部正常则完全不渲染。流式期间未被历史匹配的工具事件同样适用。
- 失败卡片保留并改成一眼可读：单个失败时标题为"<工具名> failed"（如 `Terminal failed`），有耗时时副标题给出"Failed after 2.0 s"；多个失败时标题"N tools failed"、副标题列出工具名。
- 逃生口：设置里的 **Verbose Mode**（原文案"Show tool calls, thinking, and message metadata"）恢复完整工具列表，无需新增开关。
- 未变：实时进度仍由输入框上方的状态条承担（"Using Read File…"）；最终回答不变。
- 测试：`test/chat_display_items_test.dart`（改为断言"正常工具不渲染/混合组只留失败/verbose 恢复"）、`test/gateway_activity_card_test.dart`、`test/gateway_activity_test.dart`（失败卡片新文案）。全套 1069 个测试通过，`flutter analyze` 0 issue。
- 已知边界：失败信息只来自实时事件，历史接口不下发状态字段，因此**重新打开会话后失败卡片不会重建**（本轮不为此改服务端）。

## 待办（用户提出的其余改动）

- R3：界面中文化 + 设置里可切换语言（默认中文）。
- R4：流式消息滚动行为——停在底部才自动跟随；用户上翻时不打扰。
- R5：会话历史本地缓存（打开会话不再每次全量拉取）。
- R6：长任务中"假发送失败"（服务端已接受，APP 却提示失败并回填输入框）修复。
