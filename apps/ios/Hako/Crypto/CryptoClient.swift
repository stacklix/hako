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
        var redactor=CryptoHTTPLog(request:request,secrets:secrets)
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
                let request=URLRequest(url:URL(string:"https://data-api.binance.vision/api/v3/ticker/price")!)
                guard let rows=try await json(request) as? [[String:Any]] else { throw HakoError(message:"Binance 单价格式无效。") }
                prices=try Self.binancePrices(rows)
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

// Redact structured fields before formatting; known credentials are also removed from free text.
private struct CryptoHTTPLog {
    private var secrets: Set<String>
    private let hidden = "[已隐藏]"
    init(request: URLRequest, secrets: [String]) {
        self.secrets=Set(secrets.filter { !$0.isEmpty })
        if let url=request.url,let components=URLComponents(url:url,resolvingAgainstBaseURL:false) {
            for value in [components.user,components.password].compactMap({$0}) where !value.isEmpty { self.secrets.insert(value) }
            for item in components.queryItems ?? [] where Self.sensitive(item.name) {
                if let value=item.value { collectSecret(value,field:item.name) }
            }
        }
        collect(request.allHTTPHeaderFields ?? [:])
        if let body=request.httpBody,let object=try? JSONSerialization.jsonObject(with:body,options:.fragmentsAllowed) { collect(object) }
    }
    private static func sensitive(_ name:String) -> Bool {
        let key=name.lowercased().filter { $0.isLetter || $0.isNumber }
        if ["signaturemethod","signatureversion"].contains(key) { return false }
        return ["key","auth","authentication","jwt","session","sessionid","sessionkey"].contains(key)
            || key.hasSuffix("token")
            || ["apikey","accesskey","secret","password","passwd","authorization","signature","cookie","privatekey","credential"].contains { key.contains($0) }
    }
    private mutating func collectSecret(_ value:Any, field:String) {
        if let value=value as? String,!value.isEmpty {
            secrets.insert(value)
            if value.lowercased().hasPrefix("bearer ") || value.lowercased().hasPrefix("basic ") {
                if let token=value.split(whereSeparator:{$0.isWhitespace}).last { secrets.insert(String(token)) }
            }
            if field.lowercased().contains("cookie") {
                for part in value.split(separator:";") {
                    let pair=part.split(separator:"=",maxSplits:1).map { $0.trimmingCharacters(in:.whitespaces) }
                    if pair.count == 2,!pair[1].isEmpty,!["path","domain","expires","max-age","samesite"].contains(pair[0].lowercased()) { secrets.insert(pair[1]) }
                }
            }
        }
        else if let values=value as? [Any] { for value in values { collectSecret(value,field:field) } }
        else if let values=value as? [String:Any] { for value in values.values { collectSecret(value,field:field) } }
    }
    private mutating func collect(_ object:Any) {
        if let values=object as? [String:Any] {
            for (key,value) in values {
                if Self.sensitive(key) { collectSecret(value,field:key) } else { collect(value) }
            }
        } else if let values=object as? [Any] { for value in values { collect(value) } }
    }
    func text(_ value:String) -> String {
        var result=value
        for secret in secrets.sorted(by:{$0.count > $1.count}) {
            result=result.replacingOccurrences(of:secret,with:hidden)
            if let encoded=secret.addingPercentEncoding(withAllowedCharacters:.alphanumerics) {
                result=result.replacingOccurrences(of:encoded,with:hidden,options:.caseInsensitive)
            }
            if let encoded=try? JSONSerialization.data(withJSONObject:secret,options:.fragmentsAllowed),
               let escaped=String(data:encoded,encoding:.utf8),escaped.count > 2 {
                result=result.replacingOccurrences(of:String(escaped.dropFirst().dropLast()),with:hidden)
            }
        }
        return HakoLog.sanitize(result,limit:Int.max)
    }
    private func plainText(_ value:String) -> String {
        var result=text(value)
        // Cover credential key/value pairs in non-JSON error bodies and JSON string values too.
        let name=#"(?:[A-Za-z0-9_-]*(?:token|secret|password|passwd|api[_-]?key|access[_-]?key|authorization|signature|cookie|private[_-]?key)[A-Za-z0-9_-]*)"#
        let pair="(?i)(\\b"+name+#"[\"']?\s*[:=]\s*)(?:\"(?:\\.|[^\"\\])*\"|'[^']*'|[^\s,;&<>]+)"#
        result=result.replacingOccurrences(of:pair,with:"$1\""+hidden+"\"",options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?im)((?:set-cookie|cookie|authorization|proxy-authorization)\s*:\s*)[^\r\n]*"#,with:"$1"+hidden,options:.regularExpression)
        result=result.replacingOccurrences(of:#"(?is)-----BEGIN (?:[A-Z ]*PRIVATE KEY)-----.*?-----END (?:[A-Z ]*PRIVATE KEY)-----"#,with:hidden,options:.regularExpression)
        return HakoLog.sanitize(result,limit:Int.max)
    }
    private func redact(_ object:Any) -> Any {
        if let values=object as? [String:Any] {
            return values.reduce(into:[String:Any]()) { result,item in
                result[item.key]=Self.sensitive(item.key) ? hidden : redact(item.value)
            }
        }
        if let values=object as? [Any] { return values.map(redact) }
        if let value=object as? String { return plainText(value) }
        return object
    }
    private func formatted(_ object:Any) -> String {
        guard let data=try? JSONSerialization.data(withJSONObject:redact(object),options:[.prettyPrinted,.sortedKeys,.fragmentsAllowed]),
              let value=String(data:data,encoding:.utf8) else { return "[无法格式化正文]" }
        return text(value)
    }
    private mutating func body(_ data:Data?) -> String {
        guard let data,!data.isEmpty else { return "[空]" }
        if let object=try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed) {
            collect(object)
            return formatted(object)
        }
        guard let value=String(data:data,encoding:.utf8) else { return "[非 UTF-8 正文，\(data.count) 字节]" }
        return plainText(value)
    }
    mutating func request(_ request:URLRequest) -> String {
        var components=request.url.flatMap { URLComponents(url:$0,resolvingAgainstBaseURL:false) }
        var query=[String:[String]]()
        for item in components?.queryItems ?? [] { query[item.name,default:[]].append(item.value ?? "") }
        components?.user=nil;components?.password=nil;components?.query=nil;components?.fragment=nil
        let headers=request.allHTTPHeaderFields ?? [:]
        // Discover body secrets before rendering headers or query values that might echo them.
        let contents=body(request.httpBody)
        return text("方法："+(request.httpMethod ?? "GET")+"\nURL："+(components?.string ?? "[无效地址]")
            + "\n查询参数：\n"+formatted(query)+"\n请求头：\n"+formatted(headers)
            + "\n请求正文：\n"+(request.httpBodyStream == nil ? contents : "[流式正文未读取，避免影响请求]"))
    }
    mutating func response(_ response:HTTPURLResponse,data:Data) -> String {
        let headers=response.allHeaderFields.reduce(into:[String:Any]()) { $0[String(describing:$1.key)]=$1.value }
        collect(headers)
        let contents=body(data)
        return text("响应头：\n"+formatted(headers)+"\n响应正文：\n"+contents)
    }
}
