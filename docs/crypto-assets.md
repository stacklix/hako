# 加密资产

在 Hako「金融 → 加密资产」进入。布局沿用运动记录；顶层分为概览、HTX、Binance 和链上资产。

## 配置

主应用「设置 → GitHub 配置」分别保存公开库和私有库地址及分支。原公开库配置保持不变；两个仓库共用钥匙串中的 GitHub Token，需授予对应仓库 Contents 读写权限。加密资产只使用私有库，读取和提交前均检查 GitHub 返回的 private 标记，不回退到公开库。私有库须预先创建分支和初始提交。

子应用右上角滑杆进入设置，在「交易所接口」选择 HTX 或 Binance，填写只读 API Key / Secret Key。「链上资产」直接列出观察地址，可添加、点击编辑或左滑删除；「链上浏览器」提供 TRONSCAN、Moralis 的 Token 配置入口。密钥保存到本机钥匙串，不上传归档。观察地址支持 TRON、Ethereum、BNB Smart Chain，同网络同地址不允许重复；地址可以编辑或移除。TRON 查询需 TRONSCAN Token，Ethereum / BSC 需 Moralis Token。链上范围为数据服务可估值的原生币和代币。TRON 额外计入原生 TRX 的 Stake 1.0 / 2.0 质押本金（含委托给他人的部分）、Stake 2.0 解押中及已解押待提取本金；他人委托给本地址的资源不计为本地址资产。TRX 使用账户详情统一计算，不与代币列表中的 TRX 重复累加。不含 NFT、第三方 DeFi 协议质押和借贷头寸；缺少报价或接口失败不会把该来源当作零资产写入总额。

## 同步入口

手动点击「同步资产」后按钮立即显示进度与「同步中」，等待期间重复点击不重复发起任务。完成后显示勾选和成功结果，失败时显示原因并提供「重试同步」，同时提供对应触觉反馈。页面自动采集保持静默。

同步仅由快捷指令动作「同步加密资产」和页面「同步资产」按钮触发，重复并发触发会等待同一任务。每次从主页面进入加密资产子应用时，先显示本机缓存，再在后台从各来源 API 采集一次最新数据；采集成功直接更新本机缓存和页面。切换资产页签、从设置返回或切回前台不重复查询，不显示加载动画或自动采集提示。该过程不读取或提交 GitHub。也不提供下拉刷新入口。可在系统快捷指令中配置每日个人自动化；无需打开界面运行，设备需已完成首次解锁且网络可用。系统可能限制后台执行时长，因此自动化应检查动作是否报错；失败可再次触发。应用不声称在被终止后自行每天定时运行。

所有日期采用 Asia/Shanghai。TRX 合约检查今天之前最近 7 个完整自然日，仅请求本地缺失日期及已有记录的缺失字段（本地待上传值也算已有）；更早的缺口不回溯。只缺资金费率时只请求费率接口，不依赖结算权益、价格或流水接口；只缺资金费或强平价时也只请求对应接口。每个缺失日使用当日最后一笔结算权益；这不是午夜收盘权益。资金费从完整自然日的结算流水按实际收支汇总，日费率优先汇总接口的 realized_rate；该字段为 null、缺失或空字符串时，使用同笔结算记录公布的 funding_rate。两者都无效或日期记录缺失时不填零，并提示具体失败原因，CSV 以小数保存（展示时乘 100 为百分比）。USDT 折值使用结算前最近完整分钟的 TRX/USDT 报价；HTX 最近 2000 条分钟行情无法覆盖的日期，使用 Binance 公共历史行情的对应 TRX/USDT 分钟。缺失价格时该日不写入，其他成功日期继续保存，下次仅重试仍缺失的日期或字段。强平价按用户选定口径使用本次采集时的当前强平价，CSV 不再单列 liquidation_sampled_at。它不代表归档日期的历史强平价；币本位合约返回 USD/TRX，图表与指标明确标注该单位及采集时点。接口返回空值或无有效强平价时留空，不填零。

仅每次进入加密资产子应用时获取一轮各来源最新资产；手动同步和快捷指令只同步缓存，不查询资产 API。采集时，全部已配置来源成功后覆盖当天完整总资产快照。任一来源获取失败时保留已有总额，成功获取的合约日仍单独保存。HTX 使用平台总资产估值（含合约），不重复累加 TRX 合约权益；Binance 使用钱包余额总览。链上美元报价按 USDT/USD 实时报价折算。

采集结果先保存到本机待同步记录。只有快捷指令或手动同步才读取 GitHub、合并记录并提交，上传失败保留待同步数据。同步时读取远端已有日期，已有 TRX 合约值始终保留，插入缓存中的缺失日期并填入已有行的空字段，已有值（包括零）不覆盖；并发触发会合并执行，静默采集期间收到的手动请求会等待采集完成后同步新缓存，不再重复采集。GitHub 只在提交确认后清除待同步项。

HTX 资产概览另列「今日合约」，通过 TRX-USD 当前账户信息与实时 TRX/USDT 行情展示当前权益、USDT 折值、价格、可用保证金、未实现盈亏和强平价。每次进入查询一轮，先展示上次快照及其更新时间，成功后更新显示和本机缓存，失败保留旧快照。今日资金费净收入按北京时间当天零点至采集时点的实际资金费收支汇总；今日资金费率合计仅包含该时段已结算费率，不含下一期预估费率。接口失败或费率缺失显示空值，不伪造零值。今日快照独立保存，不写入历史合约 CSV、不作为历史结算权益、不重复计入 HTX 总资产。历史合约仍只补采最近七个完整自然日中缺失的日期或字段。

## 年度文件

仅补采最近 7 个完整自然日中缺失的合约记录或字段，不导入旧数据源或修改旧格式。合约 USDT 折值在采集时使用未舍入的 TRX 权益乘对应价格，再保留两位小数；后续读取直接使用已归档折值，避免用舍入后的价格重新计算。

- `data/crypto/htx-trx/YYYY.csv`：`date,total_equity,trx_balance,trx_liquidation_price,trx_price,funding_trx,funding_rate`。前五列沿用参考文件命名，`total_equity` 为 TRX 权益乘对应 TRX/USDT 价格；强平价为采集时当前 USD/TRX 价格。
- `data/crypto/portfolio/YYYY.csv`：`date,htx,binance,chain,total`。

两个 CSV 的 `date` 均为 `yyyyMMdd`（Asia/Shanghai）。金额（含 TRX 余额、资金费、权益及各来源总资产）固定两位小数，TRX 单价和强平价固定三位小数，采用十进制四舍五入；资金费率精度不变。每种类型每天只保存一行，CSV 不再保存 sampled_at、scope、legacy_contract_equity、backfill。确切采集时间仅保留在本机缓存，归档日期用于绘图，界面不再显示无法从归档恢复的时分。来源标识只在本机缓存判断总资产是否需要更新，不上传。

正常读写仅接受当前 CSV 表头。历史导入、旧格式兼容、表头迁移及临时启动入口均已移除。

拉取远端后合并本机待同步记录，以 expectedHead 提交；冲突重新拉取，损坏 CSV 或重复日期停止覆盖。远端没有采集时间，不推测其他设备快照的先后；本机显式重采的当天快照覆盖同日远端记录。累计资金费从已有日度记录计算，不在文件中冗余存储。

## 接口依据

- [HTX 币本位永续 API](https://huobiapi.github.io/docs/coin_margined_swap/v1/en/)：用户结算记录、V3 资金流水、历史资金费率。
- [HTX 现货 API](https://huobiapi.github.io/docs/spot/v1/en/)：平台估值和 TRX/USDT 历史分钟行情。
- [Binance 钱包 API](https://developers.binance.com/en/docs/catalog/core-trading-wallet/api/rest-api/asset)：钱包总览。
- [TRONSCAN 账户代币](https://docs.tronscan.org/en/api/account/account-tokens)与[账户详情](https://docs.tronscan.org/en/api/account/account-detail)：代币分页估值及原生 TRX 余额、质押、解押本金。
- [Moralis 净值接口](https://moralis.com/how-to-get-the-net-worth-of-any-erc20-wallet-via-api/)。

- [Binance 公共分钟行情](https://github.com/binance/binance-spot-api-docs/blob/master/rest-api.md#klinecandlestick-data)：按 startTime / endTime 读取结算时点的 TRXUSDT 分钟。
