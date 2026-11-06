import Foundation
import CryptoKit

// Only read endpoints; signed requests use the host's no-redirect transport.
struct CryptoClient {
    let session: URLSession
    let logStore: HakoLogStore
    init(session: URLSession = HTTPTransport.shared, logStore: HakoLogStore = .shared) {
        self.session=session;self.logStore=logStore
    }
    static func number(_ value: Any?) throws -> Double {
        let n: Double?
        if let s = value as? String { n = Double(s) } else { n = (value as? NSNumber)?.doubleValue }
        guard let n, n.isFinite else { throw HakoError(message: "资产接口返回了无效数值。") }
        return n
    }
    func json(_ request: URLRequest, secrets: [String] = [], allowEmptyResponse: Bool = false) async throws -> Any {
        let requestID=String(UUID().uuidString.prefix(8))
        let started=ContinuousClock.now
        let path=request.url?.path ?? "[未知接口]"
        let endpoint=(request.httpMethod ?? "GET")+" "+(request.url?.host ?? "[未知主机]")+path
        var status:Int?,failure:String?,level=HakoLogLevel.info
        var redactor=HTTPLogRedactor(request:request,secrets:secrets)
        var responseDetail="未收到响应正文"
        logStore.append(source:.crypto,level:.info,message:redactor.text("开始请求 "+endpoint),detail:"请求 ID："+requestID+"\n"+redactor.request(request),fullDetail:true)
        defer {
            let duration=started.duration(to:.now).components
            let milliseconds=Double(duration.seconds)*1000+Double(duration.attoseconds)/1e15
            let result=level == .info ? "HTTP 请求成功 " : level == .warning ? "请求取消 " : "请求失败 "
            let detail="请求 ID："+requestID+"\nHTTP 状态："+(status.map(String.init) ?? "未收到响应")
                + "\n耗时："+String(format:"%.0f ms",milliseconds)+(failure.map { "\n原因："+$0 } ?? "")
                + "\n"+responseDetail
            logStore.append(source:.crypto,level:level,message:redactor.text(result+endpoint),detail:redactor.text(detail),fullDetail:true)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw HakoError(message: "资产接口未返回 HTTP 响应。") }
            status=response.statusCode
            responseDetail=redactor.response(response,data:data)
            guard (200..<300).contains(response.statusCode) else { throw HakoError(message: "资产接口请求失败（HTTP \(response.statusCode)）。") }
            if allowEmptyResponse && data.isEmpty { return NSNull() }
            let value = try JSONSerialization.jsonObject(with: data)
            if let o = value as? [String: Any], o["status"] as? String == "error" {
                let code = (o["err_code"] as? NSNumber)?.stringValue ?? "未知"
                throw HakoError(message: "HTX 接口拒绝请求（错误码 \(code)）。")
            }
            return value
        } catch is CancellationError {
            level = .warning;failure="请求已取消";throw CancellationError()
        } catch let error as HakoError {
            level = .error;failure=error.localizedDescription;throw error
        } catch {
            let underlying=error as NSError
            level = underlying.domain == NSURLErrorDomain && underlying.code == NSURLErrorCancelled ? .warning : .error
            failure="错误域：\(underlying.domain)，错误码：\(underlying.code)"
            throw HakoError(message: "资产接口请求失败，请检查配置、网络及设备时间。")
        }
    }
    static func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~"))! }
    static func query(_ values: [String: String]) -> String { values.keys.sorted().map { escape($0) + "=" + escape(values[$0]!) }.joined(separator: "&") }
    static func mac(_ data: String, secret: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: Data(secret.utf8))))
    }
    func htx(_ host: String, _ path: String, credential: CryptoCredential? = nil, params: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        let method = body == nil ? "GET" : "POST"
        var q = params
        if let credential {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            q.merge(["AccessKeyId":credential.key,"SignatureMethod":"HmacSHA256","SignatureVersion":"2","Timestamp":f.string(from: .now)]) { _, new in new }
            q["Signature"] = Self.mac([method,host,path,Self.query(q)].joined(separator: "\n"), secret: credential.secret).base64EncodedString()
        }
        var r = URLRequest(url: URL(string: "https://" + host + path + "?" + Self.query(q))!); r.httpMethod = method
        if let body { r.httpBody = try JSONSerialization.data(withJSONObject: body); r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        guard let object = try await json(r,secrets:[credential?.key ?? "",credential?.secret ?? ""]) as? [String: Any] else { throw HakoError(message: "HTX 返回格式无效。") }; return object
    }
    // Keep incomplete valuations out of daily totals and explain why the old snapshot remains.
    func htxTotal(_ c: CryptoCredential) async throws -> Double {
        let o = try await htx("api.huobi.pro", "/v2/account/valuation", credential: c, params: ["valuationCurrency":"BTC"])
        func incomplete(_ reason: String) -> HakoError {
            HakoError(message:"估值数据不完整（"+reason+"），今日总资产未更新，保留已有数据。")
        }
        guard o["success"] as? Bool == true else { throw incomplete("接口 success 未返回 true") }
        guard let d = o["data"] as? [String: Any] else { throw incomplete("缺少 data") }
        guard let updated = d["updated"] as? [String: Any], updated["success"] as? Bool == true else {
            throw incomplete("data.updated.success 未返回 true")
        }
        guard let accounts = d["profitAccountBalanceList"] as? [[String: Any]] else {
            throw incomplete("缺少账户估值列表 profitAccountBalanceList")
        }
        guard accounts.allSatisfy({ $0["success"] as? Bool == true }) else {
            throw incomplete("账户估值列表中有账户 success 未返回 true")
        }
        return try Self.number(d["totalBalance"]) * (try await price("BTC"))
    }
    func binanceTotal(_ c: CryptoCredential) async throws -> Double {
        try await binanceSnapshot(c).total
    }
    func binanceSnapshot(_ c: CryptoCredential) async throws -> CryptoBinanceSnapshot {
        var q = ["timestamp":String(Int(Date.now.timeIntervalSince1970*1000)),"recvWindow":"10000","quoteAsset":"USDT","needBalanceDetail":"true"]
        let signature = Self.mac(Self.query(q), secret:c.secret).map { String(format:"%02x",$0) }.joined()
        q["signature"] = signature
        var r = URLRequest(url: URL(string:"https://api.binance.com/sapi/v1/asset/wallet/balance?" + Self.query(q))!)
        r.setValue(c.key, forHTTPHeaderField:"X-MBX-APIKEY")
        guard let data = try await json(r,secrets:[c.key,c.secret]) as? [[String: Any]] else { throw HakoError(message:"Binance 总资产格式无效。") }
        return try await binancePrices(Self.binanceSnapshot(data,scope:CryptoDay.hash(c.key)),credential:c)
    }
    // Refresh quotes independently so cached holdings never require a balance request.
    func binancePrices(_ cached:CryptoBinanceSnapshot,credential c:CryptoCredential) async throws -> CryptoBinanceSnapshot {
        var snapshot=cached,prices=[String:Double]()
        var missing=Set<String>()
        let assets=snapshot.accounts.flatMap { $0.assets ?? [] }
        let equities=Set(assets.compactMap(\.equitySymbol))
        var equityPrices=[String:Double]()
        for symbol in equities.sorted() {
            do {
                if let price=try await binanceEquityPrice(symbol,credential:c) { equityPrices[symbol]=price }
                else { missing.insert(symbol) }
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                missing.insert(symbol)
            }
        }
        if assets.contains(where: { $0.equitySymbol == nil && !["USDT","USD"].contains($0.symbol) }) {
            do {
                prices = try await binanceSpotPrices()
            } catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                missing.formUnion(assets.filter { $0.equitySymbol == nil && !["USDT","USD"].contains($0.symbol) }.map(\.symbol))
            }
        }
        for account in snapshot.accounts.indices {
            guard let assets=snapshot.accounts[account].assets else { continue }
            snapshot.accounts[account].assets=assets.map { asset in
                var value=asset
                if let symbol=asset.equitySymbol {
                    if let price=equityPrices[symbol] { value.equityUSDPrice=price;value.unitPrice=price }
                    else if let price=asset.equityUSDPrice { value.unitPrice=price }
                    return value
                }
                if ["USDT","USD"].contains(asset.symbol) { value.unitPrice=1;return value }
                var price=prices[asset.symbol+"USDT"]
                if price == nil {
                    for quote in ["BTC","ETH","BNB","USDC","FDUSD"] {
                        if let base=prices[asset.symbol+quote],let conversion=prices[quote+"USDT"] {
                            let converted=base * conversion
                            if converted.isFinite && converted > 0 { price=converted;break }
                        }
                    }
                }
                if let price { value.unitPrice=price }
                else { missing.insert(asset.symbol) }
                return value
            }
        }
        snapshot.quoteError=missing.isEmpty ? nil : "报价暂不可用，保留上次报价；无历史报价时显示未提供："+missing.sorted().joined(separator:"、")
        return snapshot
    }
    func binanceEquityPrice(_ symbol:String,credential:CryptoCredential) async throws -> Double? {
        var request=URLRequest(url:URL(string:"https://api.binance.com/sapi/v1/equity/market/quote?"+Self.query(["symbol":symbol]))!)
        request.setValue(credential.key,forHTTPHeaderField:"X-MBX-APIKEY")
        let value=try await json(request,secrets:[credential.key,credential.secret],allowEmptyResponse:true)
        if value is NSNull { return nil }
        guard let quote=value as? [String:Any],quote["symbol"] as? String == symbol else {
            throw HakoError(message:"Binance 股票报价代码不匹配。")
        }
        return try Self.binanceEquityMidpoint(quote)
    }
    static func binanceEquityMidpoint(_ quote:[String:Any]) throws -> Double? {
        let bid=try number(quote["bidPrice"]),ask=try number(quote["askPrice"])
        guard bid > 0,ask > 0,bid <= ask else { return nil }
        let midpoint=bid + (ask-bid)/2
        return midpoint.isFinite ? midpoint : nil
    }
    func binanceSpotPrices(pairs: [String]? = nil) async throws -> [String:Double] {
        var url = URLComponents(string:"https://data-api.binance.vision/api/v3/ticker/price")!
        if let pairs {
            let symbols = String(decoding:try JSONEncoder().encode(pairs),as:UTF8.self)
            url.queryItems = [URLQueryItem(name:"symbols",value:symbols)]
        }
        let request = URLRequest(url:url.url!)
        guard let rows = try await json(request) as? [[String:Any]] else {
            throw HakoError(message:"Binance 单价格式无效。")
        }
        return try Self.binancePrices(rows)
    }
    static func binancePrices(_ rows:[[String:Any]]) throws -> [String:Double] {
        var prices=[String:Double]()
        for row in rows {
            guard let symbol=row["symbol"] as? String else { throw HakoError(message:"Binance 交易对格式无效。") }
            let price=try number(row["price"])
            if price > 0 { prices[symbol]=price }
        }
        return prices
    }
    static func binanceSnapshot(_ rows:[[String:Any]],scope:String) throws -> CryptoBinanceSnapshot {
        let accounts = try rows.enumerated().map { index,row in
            var assets:[CryptoBinanceAsset]?
            if let raw = row["assetBalances"] {
                guard let details=raw as? [[String:Any]] else { throw HakoError(message:"Binance 币种明细格式无效。") }
                assets=try details.map { asset in
                    guard let symbol=asset["asset"] as? String, !symbol.isEmpty else { throw HakoError(message:"Binance 币种名称无效。") }
                    return try CryptoBinanceAsset(symbol:symbol,name:asset["assetName"] as? String ?? symbol,
                        free:Self.number(asset["free"]),locked:Self.number(asset["locked"]),
                        frozen:Self.number(asset["freeze"]),withdrawing:Self.number(asset["withdrawing"]))
                }.filter { $0.quantity != 0 }.sorted { $0.symbol < $1.symbol }
                guard Set(assets!.map(\.id)).count == assets!.count else { throw HakoError(message:"Binance 币种明细重复。") }
            }
            return try CryptoBinanceAccount(name:row["walletName"] as? String ?? "账户 \(index+1)",balance:Self.number(row["balance"]),assets:assets)
        }
        guard Set(accounts.map(\.id)).count == accounts.count,
              accounts.reduce(0, { $0 + $1.balance }).isFinite else { throw HakoError(message:"Binance 账户明细无效。") }
        return CryptoBinanceSnapshot(scope:scope,sampledAt:.now,accounts:accounts.sorted {
            $0.balance == $1.balance ? $0.name < $1.name : $0.balance > $1.balance
        })
    }
    func price(_ symbol: String) async throws -> Double {
        if symbol == "USDT" { return 1 }
        let o = try await htx("api.huobi.pro", "/market/detail/merged", params:["symbol":symbol.lowercased()+"usdt"])
        guard let tick = o["tick"] as? [String: Any] else { throw HakoError(message:"缺少 \(symbol) 的 USDT 报价。") }
        let price = try Self.number(tick["close"])
        guard price > 0 else { throw HakoError(message:"资产价格无效。") }; return price
    }
}

extension CryptoClient {
    func htxAssetDetails(_ credential: CryptoCredential, scope: String, now: Date,
                         previous: CryptoHTXSnapshot?) async throws -> CryptoHTXSnapshot {
        var snapshot = previous ?? CryptoHTXSnapshot(scope:scope,sampledAt:now)
        snapshot.sampledAt = now
        snapshot.balanceVersion = CryptoHTXSnapshot.currentBalanceVersion
        snapshot.errors = []
        let accounts: Result<[[String:Any]],Error>
        do {
            let response = try await htx("api.huobi.pro","/v1/account/accounts",credential:credential)
            guard response["status"] as? String == "ok", let rows = response["data"] as? [[String:Any]],
                  rows.allSatisfy({ $0["type"] is String }) else {
                throw HakoError(message:"HTX 账户列表响应无效。")
            }
            accounts = .success(rows)
        } catch {
            try Task.checkCancellation()
            accounts = .failure(error)
        }
        for source in CryptoHTXSnapshot.Source.queried {
            do {
                snapshot.holdings[source] = try await htxHoldings(source,credential:credential,accounts:accounts)
                if source == .linearSwap {
                    snapshot.holdings.removeValue(forKey:.crossSwap)
                    snapshot.holdings.removeValue(forKey:.isolatedSwap)
                }
            } catch {
                try Task.checkCancellation()
                snapshot.errors.append(source.title + "：" + error.localizedDescription)
            }
        }
        return try await htxAssetPrices(snapshot)
    }

    func htxAssetPrices(_ snapshot: CryptoHTXSnapshot) async throws -> CryptoHTXSnapshot {
        var result = snapshot
        result.quoteError = nil
        let symbols = Set(result.holdings.values.flatMap { $0.map(\.symbol) }).subtracting(["USDT"])
        guard !symbols.isEmpty else { return result }
        do {
            let response = try await htx("api.huobi.pro","/market/tickers")
            guard response["status"] as? String == "ok", let rows = response["data"] as? [[String:Any]] else {
                throw HakoError(message:"行情响应无效。")
            }
            var quotes: [String: Double] = [:]
            for row in rows {
                if let pair = row["symbol"] as? String, let price = try? Self.number(row["close"]), price > 0 {
                    quotes[pair.lowercased()] = price
                }
            }
            var missing: [String] = []
            for symbol in symbols.sorted() {
                let base = symbol.lowercased()
                let price = quotes[base+"usdt"] ?? ["btc","eth"].compactMap { bridge -> Double? in
                    guard let first = quotes[base+bridge], let second = quotes[bridge+"usdt"] else { return nil }
                    return first * second
                }.first
                if let price, price.isFinite { result.prices[symbol] = price }
                else { missing.append(symbol) }
            }
            if !missing.isEmpty { result.quoteError = "暂无最新报价：" + missing.joined(separator:"、") }
        } catch {
            try Task.checkCancellation()
            result.quoteError = "报价更新失败：" + error.localizedDescription
        }
        return result
    }

    private func htxHoldings(_ source: CryptoHTXSnapshot.Source, credential: CryptoCredential,
                             accounts: Result<[[String:Any]],Error>) async throws -> [CryptoHTXSnapshot.Holding] {
        let spotHost = "api.huobi.pro"
        let invalid = HakoError(message:"账户明细响应无效。")
        switch source {
        case .spot, .crossMargin:
            let isMargin = source == .crossMargin
            let accountType = isMargin ? "super-margin" : "spot"
            var holdings: [CryptoHTXSnapshot.Holding] = []
            // Unopened cross-margin accounts are absent from the account list.
            for account in try accounts.get() where account["type"] as? String == accountType {
                guard let id = account["id"] as? Int, id > 0 else { throw invalid }
                let balance = try await htx(spotHost,"/v1/account/accounts/\(id)/balance",credential:credential)
                guard balance["status"] as? String == "ok",
                      let data = balance["data"] as? [String:Any], let rows = data["list"] as? [[String:Any]] else { throw invalid }
                holdings += try Self.htxBalanceRows(rows,id:source.rawValue+"-\(id)",label:isMargin ? "全仓" : "",margin:isMargin)
            }
            return holdings
        case .isolatedMargin:
            let response = try await htx(spotHost,"/v1/margin/accounts/balance",credential:credential)
            guard response["status"] as? String == "ok", let accounts = response["data"] as? [[String:Any]] else { throw invalid }
            return try accounts.flatMap { account in
                guard let pair = account["symbol"] as? String, !pair.isEmpty,
                      let rows = account["list"] as? [[String:Any]] else { throw invalid }
                return try Self.htxBalanceRows(rows,id:source.rawValue+"-"+pair,label:"逐仓 · "+pair.uppercased(),margin:true)
            }
        case .coinSwap:
            let response = try await htx("api.hbdm.com","/swap-api/v1/swap_account_info",credential:credential,body:[:])
            guard response["status"] as? String == "ok", let rows = response["data"] as? [[String:Any]] else { throw invalid }
            return try rows.compactMap { row in
                let quantity = try Self.number(row["margin_balance"])
                guard quantity != 0 else { return nil }
                let contract = row["contract_code"] as? String
                let symbol = row["symbol"] as? String ?? contract?.split(separator:"-").first.map(String.init)
                guard let symbol, !symbol.isEmpty else { throw invalid }
                let label = source.title + (contract.map { " · " + $0 } ?? "")
                return CryptoHTXSnapshot.Holding(id:source.rawValue+"-"+(contract ?? symbol),symbol:symbol.uppercased(),
                    label:label,quantity:quantity,available:try? Self.number(row["margin_available"]),
                    frozen:try? Self.number(row["margin_frozen"]),unrealized:try? Self.number(row["profit_unreal"]))
            }
        case .linearSwap:
            let response = try await htx("api.hbdm.com","/v5/account/balance",credential:credential)
            let code = (response["code"] as? NSNumber)?.stringValue ?? response["code"] as? String
            guard code == "200" else {
                if let code, let number = Int(code) { throw HakoError(message:"HTX V5 查询失败（错误码 \(number)）。") }
                throw invalid
            }
            guard let data = response["data"] as? [String:Any], let rows = data["details"] as? [[String:Any]] else { throw invalid }
            // Each currency row already contains the account equity. Do not add the
            // separate isolated-equity field or the top-level account total to it.
            var seen = Set<String>()
            return try rows.compactMap { row in
                guard let currency = row["currency"] as? String, !currency.isEmpty,
                      seen.insert(currency.uppercased()).inserted else { throw invalid }
                let equity = try Self.number(row["equity"])
                guard equity != 0 else { return nil }
                let symbol = currency.uppercased()
                return CryptoHTXSnapshot.Holding(id:source.rawValue+"-"+symbol,symbol:symbol,label:source.title,
                    quantity:equity,available:try? Self.number(row["available_margin"]),
                    unrealized:try? Self.number(row["profit_unreal"]))
            }
        case .crossSwap, .isolatedSwap:
            throw invalid
        }
    }

    static func htxBalanceRows(_ rows: [[String:Any]], id: String, label: String, margin: Bool) throws -> [CryptoHTXSnapshot.Holding] {
        var balances: [String:[String:Double]] = [:]
        let supported = margin ? ["trade","frozen","loan","interest"] : ["trade","frozen"]
        for row in rows {
            guard let type = row["type"] as? String else { throw HakoError(message:"余额类型缺失。") }
            guard supported.contains(type) else { continue }
            guard let currency = row["currency"] as? String, !currency.isEmpty else { throw HakoError(message:"币种缺失。") }
            let amount = try Self.number(row["balance"])
            balances[currency.uppercased(),default:[:]][type,default:0] += amount
        }
        return try balances.keys.sorted().compactMap { symbol in
            let amounts = balances[symbol] ?? [:]
            let available = amounts["trade"] ?? 0
            let frozen = amounts["frozen"] ?? 0
            let loan = abs(amounts["loan"] ?? 0)
            let interest = abs(amounts["interest"] ?? 0)
            let quantity = available + frozen - loan - interest
            guard quantity.isFinite else { throw HakoError(message:"账户余额无效。") }
            guard quantity != 0 || available != 0 || frozen != 0 || loan != 0 || interest != 0 else { return nil }
            return CryptoHTXSnapshot.Holding(id:id+"-"+symbol,symbol:symbol,label:label,quantity:quantity,
                available:available,frozen:frozen,loan:margin ? loan : nil,interest:margin ? interest : nil)
        }
    }
}
