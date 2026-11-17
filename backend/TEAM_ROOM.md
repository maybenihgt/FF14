# 2v2 团队分析房间（第一阶段）

这是一个**仅供私人沙盒**使用的四人自愿数据中继服务。它不是 Dalamud 游戏状态读取器，不连接 FF14，不读取网络包，也不发送任何游戏输入。

## 功能

- 创建 A/B 两队的 2v2 分析房间（每队最多两人）。
- 四名参与者必须分别明确同意后，房间快照才会对成员可见。
- 每名参与者只能提交自己的快照；服务端不会推断或伪造手牌。
- 房间数据仅保存在内存，默认 2 小时过期；服务重启后数据清空。
- 每位参与者持有独立 token；读取房间和提交数据都需要 token。
- 仅允许 仅 `sandbox` 模式；不支持实时匹配、实时对局数据共享或自动操作。

## 启动

需要 Python 3.10+，无第三方依赖：

```bash
python backend/team_room.py
```

默认监听 `127.0.0.1:8770`。可用环境变量 `TEAM_ROOM_HOST`、`TEAM_ROOM_PORT`、`TEAM_ROOM_TTL_SECONDS` 修改。

## API

1. 创建房间（仅 `sandbox` 模式）：`POST /v1/team-rooms`

```json
{"mode":"sandbox","name":"Player-A1","team":"A","consent":true}
```

返回 `room_id`、`invite_code` 和创建者的 `participant_token`。

2. 其余三人加入：`POST /v1/team-rooms/{room_id}/join`

```json
{"invite_code":"<invite_code>","name":"Player-A2","team":"A","consent":true}
```

另外两名玩家分别加入 B 队。每人会获得自己的 `participant_token`。

3. 提交个人快照：`POST /v1/team-rooms/{room_id}/snapshot`

请求头：`Authorization: Bearer <participant_token>`

```json
{"snapshot":{"source":"manual-sandbox-state","hand":[],"discards":[],"scores":[],"turn":0}}
```

快照字段目前保持开放，便于下一阶段适配 Doman Mahjong 的状态结构。**只有四人都加入且明确同意后，GET 才会返回四人的快照。**

4. 查看房间：`GET /v1/team-rooms/{room_id}`

请求头同上。未满足四人同意时，只返回成员与状态，不返回任何快照。

5. 离开：`POST /v1/team-rooms/{room_id}/leave`，同样需要 token。

## 安全边界与限制

- 不要把此服务暴露到公网；当前版本没有 TLS、账号体系或持久化审计。
- 邀请码和个人 token 等同于访问凭据，不要公开分享。
- 当前重点是房间、同意门槛和积分统计；不做牌谱回放模拟。积分由每位玩家在每局结束后提交当前游戏内积分，系统计算变化值、累计变化、最高积分和局数。
- 本阶段不包含“故意放铳、送分、干扰对手”等操纵结果的策略，也不向 FF14 发送操作。


6. 提交本局结束后的当前积分：`POST /v1/team-rooms/{room_id}/score`

请求头：`Authorization: Bearer <participant_token>`

```json
{"rating": 1250}
```

每位玩家每局结束后提交一次自己的当前积分。系统会计算：
- 当前积分
- 与上次记录相比的本局积分变化（首次提交记为 0）
- 历史最高积分
- 累计积分变化
- 已记录局数

房间查询结果会显示每名成员的积分统计，以及 A/B 两队当前积分合计。当前版本仅保存在内存中，服务重启或房间过期后统计会清空；持久化存储留待后续实现。
