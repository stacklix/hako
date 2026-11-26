# 共享交易日历

交易日历保存在投资数据库的独立表 `market_trading_calendars`。每个市场每年一条记录，联合主键为 `(market, year)`。`CN_A` 为 A 股与境内场内 ETF，`US` 为美股与美股 ETF，`HK` 为港股与香港上市 ETF。场外基金净值的公布日期不由交易日历推断。

`trading_days` 为严格的 ASCII `0/1` 字符串，第 1 位对应当地日期 1 月 1 日；`1` 表示交易日，`0` 表示休市。平年必须 365 位，闰年必须 366 位。来源必须提供全年每个自然日，不允许把缺失日期填成 `0`。读取不到该市场该年的记录表示日历未知，不表示整年休市。

表中另存 `session_overrides`、`source`、`updated_at`、`updated_by`、`revision`。`updated_by` 为服务端记录的写入应用 ID；版本从 1 起，每次成功更新递增。日历不按账户、标的或来源重复保存，不写入价格表。

## 开放读取

```http
GET /api/v1/market/calendars?market=US&year=2026
```

读取无需登录或应用凭据。返回 `market`、`year`、`tradingDays`、`sessionOverrides`、`source`、`updatedAt`、`updatedBy` 和 `revision`。不存在返回 HTTP 404 `calendar_not_available`；非法市场或年份返回 HTTP 400。支持年份 1970–2100。读取按客户端 IP 限制每分钟 120 次，`Cache-Control: no-cache`，客户端可将已读取日历保存在自己的缓存中并主动刷新。

行情需求读取 `GET /api/v1/market/update-targets` 同样开放，不需要配置读取权限。清单只含公共标的和所需行情日期，不返回账户、金额或交易流水。清单上的短时目标签名不授予写入权限。响应中的 `calendarRequests` 列出缺少的 `{market,year}`，供第三方补充日历；采集脚本也会明确记录这些缺项。

## 第三方写入

```http
PUT /api/v1/market/calendars
X-Hako-Client: <应用 Client ID>
Authorization: Bearer <应用 Client Secret>
Content-Type: application/json
```

在第三方应用管理中开启 `calendarWriteEnabled`（更新交易日历），默认关闭。`marketWriteEnabled`（写入行情与汇率）与它独立：任何一项均不授予另一项权限。没有读取开关，读取始终开放。停用应用、撤销写权限、轮换 SK 后，后续写入重新鉴权；不接受来自浏览器页面的应用密钥写入请求。

请求字段：

| 字段 | 说明 |
| --- | --- |
| `market` | `CN_A`、`US` 或 `HK` |
| `year` | 年份 |
| `tradingDays` | 完整的 365/366 位字符串 |
| `sessionOverrides` | 日期到特殊时段数组的映射；正常交易日可以省略 |
| `source` | 数据来源说明，1–100 字节，不含控制字符 |
| `expectedRevision` | 新建为 `0`；更新使用最近读取到的版本，必填 |

时段格式为 `{"open":"09:30","close":"13:00"}`。时间按市场本地时区解释：`CN_A` 为 Asia/Shanghai，`US` 为 America/New_York，`HK` 为 Asia/Hong_Kong。美国夏令时由时区数据库换算，不写死 UTC 偏移。

默认正常交易时段：A 股 09:30–11:30、13:00–15:00；美股 09:30–16:00；港股 09:30–12:00、13:00–16:00。特殊时段通过日期覆盖，例如 `"2026-11-27":[{"open":"09:30","close":"13:00"}]`。覆盖日期必须位于该年且位值为 `1`；每个日期最多四段，同一天内按先后排序、不得重叠。休市日位值为 `0`，不得另配开市时段。单个请求沿用 16 KiB 上限。

验证失败返回 HTTP 400 `invalid_trading_calendar`，整条记录不变；版本冲突返回 HTTP 409 `calendar_revision_conflict`，需重新读取、核对后提交。写入权限不足返回 HTTP 403 `calendar_write_permission_required`，无效或停用的应用返回 HTTP 401。成功返回服务端保存的完整记录，包括新版本和更新时间。写入按应用限制每分钟 60 次。

## 采集与使用

第三方可使用 Tushare `trade_cal` 获取 A 股日历、`hk_tradecal` 获取港股日历、`us_tradecal` 获取美股日历。必须逐日检查覆盖完整性后按日期顺序拼接位串。各接口的积分权限不同；提前收盘等时段需另外按交易所公告维护，`is_open` 字段本身不能表达半日市。

后台生成行情需求、App 直接采集使用同一份年度日历。正常开盘后才查询盘中最新价；午休、休市和收盘后不发送盘中任务。历史日线截至最近已经收盘的交易日，缺失时补查原始交易日期，既有收盘价直接复用。跨年查找最近交易日可能需要上一年的日历；日历缺失时暂停相应市场的需求，不按周末规则猜测。

基金净值、加密资产、国内衍生品和 ECB 汇率不套用股票市场日历。基金净值只写实际公布日期；加密资产仍按 UTC 连续交易。

## 数据库版本

投资数据库 schema 为 10；现有 schema 9 需要在部署前备份并新增该表，再将 `PRAGMA user_version` 更新为 10。建表 SQL 以 `market_calendars.go` 中的 `marketCalendarsSQL` 为准。沿用项目严格版本检查，不自动转换或清空已有账本，不会为新表伪造交易日历。

官方接口文档：[A 股交易日历](https://tushare.pro/document/1?doc_id=26)、[港股交易日历](https://tushare.pro/document/2?doc_id=250)、[美股交易日历](https://tushare.pro/document/2?doc_id=253)、[NYSE 交易时间与休市安排](https://www.nyse.com/markets/hours-calendars)。
