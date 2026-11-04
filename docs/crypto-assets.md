# 加密资产

在 Hako「金融 → 加密资产」进入。布局沿用运动记录；顶层分为概览、HTX、Binance 和链上资产。

## 配置

主应用「设置 → GitHub 配置」分别保存公开库和私有库地址及分支。原公开库配置保持不变；两个仓库共用钥匙串中的 GitHub Token，需授予对应仓库 Contents 读写权限。加密资产只使用私有库，读取和提交前均检查 GitHub 返回的 private 标记，不回退到公开库。私有库须预先创建分支和初始提交。

子应用右上角滑杆进入设置，填写交易所只读 API Key / Secret Key。密钥保存到本机钥匙串，不上传归档。观察地址支持 TRON、Ethereum、BNB Smart Chain，同网络同地址不允许重复；地址可以编辑或移除。TRON 查询需 TRONSCAN Token，Ethereum / BSC 需 Moralis Token。链上范围为数据服务可估值的原生币和代币，不含 NFT、协议质押和借贷头寸；缺少报价或接口失败不会把该来源当作零资产写入总额。

## 统一自动触发

快捷指令动作「同步加密资产」和打开子应用使用同一任务，重复并发触发会等待同一任务。可在系统快捷指令中配置每日个人自动化；无需打开界面运行，设备需已完成首次解锁且网络可用。系统可能限制后台执行时长，因此自动化应检查动作是否报错；失败可再次触发。应用不声称在被终止后自行每天定时运行。

所有日期采用 Asia/Shanghai。TRX 合约每次读取前一天，使用该日最后一笔结算权益；这不是午夜收盘权益。资金费从完整自然日的结算流水按实际收支汇总，日费率为实际结算费率之和，CSV 以小数保存（展示时乘 100 为百分比）。USDT 折值使用结算前最近完整分钟的 TRX/USDT 报价。强平价按用户选定口径使用本次采集时的当前强平价，并单独保存 liquidation_sampled_at。它不是昨日强平价；币本位合约返回 USD/TRX，图表与指标明确标注该单位及采集时点。接口返回空值或无有效强平价时留空，不填零。

总资产使用当天首次成功采集的完整快照，仅汇总已配置的来源。HTX 使用平台总资产估值（含合约），不重复累加 TRX 合约权益；Binance 使用钱包余额总览。链上美元报价按 USDT/USD 实时报价折算。

两类任务分别判断成功状态：昨天的合约记录和今天的总资产记录确认已在私有库后，当天再次触发不重新采集或提交。切换来源配置后独立判断，避免混淆账户。上传失败会保留本地待同步记录；只有 GitHub 确认后才清除。下次首先重试待同步项。未采集的日期保持缺失，不填零、不虚构历史。

## 年度文件

本版本包含一次性历史补齐：优先通过 HTX API 批量读取 2026-09-01 至昨天的日度权益、行情、资金费和费率。权益取当日最后结算记录；历史 USDT 行情取当天最后完整小时。API 缺失的字段再从 `stacklix/storage` 固定提交 `5c27ffd882aa98219212cc6ec0a545dc3721b39d` 下的 `data/htx_equity.csv` 补齐。旧合约估值仅在接口权益或价格不完整时作为估值回退，保存在 `legacy_contract_equity`，不混入全局总资产。两边都没有的字段留空；成功读取完整资金费窗口后，无资金费流水的日期可记为零。已有正常日度记录不覆盖。临时补齐记录以 `backfill` 标识，接口失败时保留已有字段，下次继续尝试；整个补齐成功后记录完成标记。下个版本可删除 CryptoHistoricalAPI / CryptoLegacyBackfill 及 Store 调用，私有库数据不受影响。

- `data/crypto/htx-trx/YYYY.csv`：结算日期、结算时间、来源范围标识、TRX 权益、USDT 价格、采集时当前强平价（可空）及其采集时间、日资金费与日实际费率。
- `data/crypto/portfolio/YYYY.csv`：日期、采集时间、来源范围标识、HTX / Binance / 链上估值和合计。

CSV 表头统一，非该类别字段为空。日期与来源范围共同标识一行；范围为 API Key 与观察地址集合的不可逆 SHA-256 标识，不含明文凭据。拉取远端后合并待同步记录，以 expectedHead 提交；冲突重新拉取，损坏 CSV 停止覆盖。累计资金费从已有日度记录计算，不在文件中冗余存储。

## 接口依据

- [HTX 币本位永续 API](https://huobiapi.github.io/docs/coin_margined_swap/v1/en/)：用户结算记录、V3 资金流水、历史实际费率。
- [HTX 现货 API](https://huobiapi.github.io/docs/spot/v1/en/)：平台估值和 TRX/USDT 历史分钟行情。
- [Binance 钱包 API](https://developers.binance.com/en/docs/catalog/core-trading-wallet/api/rest-api/asset)：钱包总览。
- [TRONSCAN 账户代币](https://docs.tronscan.org/en/api/account/account-tokens)。
- [Moralis 净值接口](https://moralis.com/how-to-get-the-net-worth-of-any-erc20-wallet-via-api/)。
