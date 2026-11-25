# 外部行情更新

服务端 0.8.21 提供行情需求查询和批量写入。外部系统负责访问行情提供商；Hako 不向外部系统提供行情商凭据、账户余额或交易明细。

## 授权

在「第三方应用 → 应用权限」分别开启 `marketReadEnabled` 和 `marketWriteEnabled`，两项默认关闭。复用应用 AK/SK：

```http
X-Hako-Client: <AK，即应用 ID>
Authorization: Bearer <SK>
Content-Type: application/json
```

这些凭据只供服务端调用，不放到浏览器。接口拒绝带 Origin 或 Sec-Fetch-Site 的请求。关闭应用、撤销权限或轮换密钥后，后续请求重新校验；应用配置变更会使此前签发的更新目标失效。行情接口共用每应用每分钟 120 次限制。

## 查询待更新数据

`GET /api/v1/market/update-targets?limit=100&cursor=<上一页 nextCursor>`，`limit` 为 1–500。

```json
{
  "targets": [{
    "targetId": "<服务端签发的目标>",
    "key": "close|<instrument-id>",
    "kind": "daily_close",
    "instrumentId": "<instrument-id>",
    "symbol": "BTCUSDT",
    "exchange": "BINANCE",
    "currency": "USD",
    "priceType": "close",
    "source": "external:<应用 ID>",
    "fromDate": "2026-11-01",
    "throughDate": "2026-11-24",
    "expiresAt": 1795608000
  }],
  "nextCursor": "",
  "pollAfterSeconds": 60,
  "maxDecimalPlaces": 4,
  "revision": 12
}
```

- `daily_close`：持有或曾交易标的的历史收盘价／净值缺口，每段最多 366 个自然日。
- `latest`：使用中或关注标的的当日价格。已存在当日正式值或五分钟内的价格时不返回。
- `fx`：账本所需币种兑人民币的日汇率，使用 `baseCurrency`、`quoteCurrency`，日期按北京时间。

已有正式历史数据直接复用。非加密资产默认排除周末，交易所节假日由提供商实际返回结果确认；加密资产按 UTC 日期，其余标的使用交易所日期。美股区分夏令时。最新值和日终值分别处理，不把未收盘值当成正式历史。

目标有效期 15 分钟，绑定当前应用及允许写入的标的、日期范围、类型、来源。外部系统不能修改目标或自选其他账本、手动估值和快照表。分页采用 keyset cursor；补完一轮后从空 cursor 重新查询，以获取后续缺口。

## 批量写入

`POST /api/v1/market/quote-batches`：

```json
{
  "items": [{
    "targetId": "<查询返回的 targetId>",
    "quotes": [{
      "date": "2026-11-24",
      "value": "8211.8900",
      "observedAt": "2026-11-25T02:00:00Z"
    }],
    "complete": true
  }]
}
```

`value` 是十进制字符串，必须大于零，最多四位有效小数（末尾零不计）；超过精度会拒绝，不静默舍入。`observedAt` 为提供商观察／发布该值的时间，使用带时区的 RFC 3339 格式。不得把旧报价标成新的观察时间。日期必须落在签发目标范围内。

每批最多 500 个目标、5,000 条观察值，单目标最多 1,000 条。每个目标先完整校验，任一记录无效时该目标全部拒绝；其他有效目标可成功。响应逐目标返回：

```json
{"results":[{"targetId":"<原目标>","status":"updated","count":1}],"revision":13}
```

`status` 为 `updated`、`unchanged` 或 `rejected`；拒绝时带 `error`。HTTP 200 仍须检查每项结果。认证失败为 401，权限不足为 403，频率限制为 429；目标过期需重新查询，存储失败可重试原数据。

`complete:true` 只用于提供商成功查询了整个目标日期范围的历史或汇率请求。缺少的日期记录为「本次未发布」，不生成零价格，也不沿用前值写入行情。该空结果保留 15 分钟后允许复查，避免尚未发布的净值永久跳过。请求失败或只查了部分范围时使用 `false`。

相同标的、日期、价格类型和来源执行单条 upsert；时间更新的报价覆盖旧值，较旧的观察值忽略，正式值不被临时值降级。重复发送相同数据不产生重复记录。其他日期和其他来源保留，手动估值不受影响。默认需求清单只补历史缺口，不会主动重新请求已保存的历史数据来发现行情源的事后修正。

行情写入不接收账本 generation，不做账本版本冲突检查，也不推进 generation。实际行情变化仅更新估值输入 revision 和最早失效日期，供客户端刷新缓存及现有日终快照流程使用；行情无变化时不推进 revision。

## 账本增量保存

iOS 普通保存改用 `POST /api/v1/investment/book/changes`（Console 认证）。请求提供 `generation`、缓存 `revision`、`dirtyFrom`、`through` 和按表分组的 `changes`：

```json
{
  "generation": 5,
  "revision": 12,
  "dirtyFrom": "2026-11-24",
  "through": null,
  "changes": {
    "investment_events": {
      "upserts": [{"id":"<交易 ID>","account_id":"<账户 ID>","event_type":"deposit","effective_date":"2026-11-24","sequence":"0","amount":"100"}],
      "deletes": [{"id":"<删除的交易 ID>"}]
    }
  }
}
```

仅写入实际变化的记录；删除只带主键。跨表修改在同一事务校验引用并提交，任一错误整体回滚。账户、交易等继续检查账本 generation，冲突返回 409，客户端重新读取并要求用户核对。服务端成功后再更新本地账本。

响应只返回已确认的增量和元数据。`reloadRequired:true` 表示客户端缓存 revision 已落后，保存仍可成功，随后重新读取完整数据；该字段不作为行情写入的前置版本检查。派生快照提交仍验证其输入 revision，避免使用旧行情计算的结果清除新行情的失效标记。

`GET /api/v1/investment/book` 继续读取全量账本；显式全量导入／恢复保留原 PUT 接口，不作为普通编辑保存路径。没有修改报告功能。
