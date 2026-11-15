# 投资记账

## 加密货币账户（0.4）

加密货币账户提供「现货」和「通用」两种标的，沿用现有账户卡片、持仓详情和原生表单布局。

- 现货按数量与行情估值；「调整余额」填写调整后的币数量，不填写美元市值。
- 通用标的只需名称，使用账户币种 USD，不依赖交易所目录、行情、保证金或定投。
- 首次录入填写投入金额，可选填当前余额；不填时余额等于投入金额。可以填写零余额。
- 后续「投入」「取出」同时改变账户现金、标的余额和净投入，不改变累计盈亏。
- 「调整余额」填写该日的实际余额，差额只改变盈亏，不记为投入或取出；允许调整到零，禁止负余额。
- 累计盈亏 = 当前余额 − 累计投入 + 累计取出。全部取出后保留历史盈亏，之后可以再次投入。

记账助手使用 `generic` 类型，以 `buy` / `sell` 记投入与取出（`price` 填金额，`quantity` 为 1）；`asset_balance` 记余额调整。首次投入可用 `settled_amount` 填实际余额。`crypto_contract` 和 `funding_balance` 已移除。

## 历史迁移与升级要求

当前投资数据库使用 schema 3，其他数据库仍为 schema 2。临时清理代码、启动调用和专用迁移测试已移除；新库直接创建 schema 3，已有 schema 3 账本正常打开，schema 2 会被拒绝且不清理其数据。

仍为 schema 2 的实例须先使用包含一次性迁移的提交 `7fd3ced`（服务端 0.4.0）成功启动一次，再升级到当前代码。部署前保留数据库备份。迁移在一个事务内完成数据清理、字段移除、快照失效和版本标记，失败全部回滚。

历史迁移的清理范围仅限投资记账中的加密合约：

- 删除 `crypto_contract` 标的及其交易、资金费、保证金等流水、行情、关注、定投及执行记录；同步删除没有标的关联的旧 `derivative_funding` 流水。
- 删除 `investment_assets.collateral_asset_id`。
- 删除 `market_derivative_specs` 的 `pricing_model`、`settlement_basis`、`settlement_unit`。
- 删除 `investment_derivative_event_details` 的 `funding_target`、`settlement_to_account_rate`。
- 清除受影响账本的日、账户日和月统计快照，交由 iOS 按保留流水重算；增加所有账本的 generation / revision，拒绝迁移前的过期写入。

现有库没有仅用于加密合约的独立持久表。期货仍使用 `market_derivative_specs` 的乘数、到期日，以及 `investment_derivative_event_details` 的方向、交易动作、保证金字段，因此保留这些共用表。资产的 `settlement_unit` 同时用于其他资产结算，亦保留。独立的「加密资产」子应用不在本次清理范围内。

该清理不会把旧合约转换为通用标的，也不会生成补偿性现金流水。需要继续记录的通用标的由用户按实际投入和余额重新登记。

清理后的 schema 3 不支持旧版服务端回退读取。客户端接口和通用标的的记账逻辑不受临时迁移代码移除的影响。
