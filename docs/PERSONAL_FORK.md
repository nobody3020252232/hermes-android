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

### R8 — 2026-10-01（上翻阅读时不再被新内容拉回底部 → R4 落地）
- 复现（widget 测试可稳定重放）：流式回答进行中，用户**短促上滑**（手指只移动约 120–150px，惯性把内容带到距底部 ~330px 处）后，下一个 delta 到达 → 视图被强行拉回底部（实测 1586 → 2056）。长滑动（400px）不会，因为那时已超过旧阈值。
- 根因：跟随开关只在**手指还在屏幕上**的 drag 更新里计算，用的是 200px 的"靠近底部"阈值；短促上滑时手指抬起的位置仍在阈值内 → 跟随保持开启 → 惯性和后续 delta 互相打架。
- 修复（`ChatScrollCoordinator` + `chat_screen.dart`）：
  - 新增更紧的"读者就在底部"容差 `userEndTolerance = 48`（`isAtUserEnd`），与"可以开始跟随"的 200px 阈值（`isNearEnd`）分开；
  - 用户滚动改为**在 `ScrollEndNotification` 上按落点判定**（惯性结束后的实际位置说了算），drag 过程中仍实时更新；新增 `_userScrollActive` 跟踪一次用户滚动；
  - 用户一旦拖动，立即中止开屏的对齐循环（最多 12 帧的 `jumpTo`），读者的位置优先。
- 行为：上翻后新内容到达只会累计右下角"↓ N new"角标（原有能力），点它或自己滑回底部才恢复跟随；回到底部后跟随自动恢复。
- 测试：`test/chat_history_scroll_test.dart` 新增"短促上滑不被拉回"（含角标断言）、"滑回底部恢复跟随"、以及 `isAtUserEnd` vs `isNearEnd` 的规则测试。全套 1072 个测试通过，`flutter analyze` 0 issue。

## 待办（用户提出的其余改动）

- R3：界面中文化 + 设置里可切换语言（默认中文）。
- R4：流式消息滚动行为——停在底部才自动跟随；用户上翻时不打扰。**已由 R8 落地**（2026-10-01）。
- R5：会话历史本地缓存（打开会话不再每次全量拉取）。
- R6：长任务中"假发送失败"（服务端已接受，APP 却提示失败并回填输入框）修复。
