import Foundation

@main struct WorkshopBrowserTests {
    static func main() {
        let screenshot = URL(string: "https://nux.luckyqiao.com/chore/images/example.png?size=full#preview")!
        let link = WorkshopBrowserLink(url: screenshot)
        precondition(link?.url == screenshot, "Screenshot links must keep their full query and fragment")
        precondition(link?.id == screenshot.absoluteString)
        for value in ["https://example.com", "HTTP://192.168.0.2:8000/page", "http://localhost:8123/", "https://example.com/path?next=https%3A%2F%2Fother.example"] {
            precondition(WorkshopBrowserLink.allows(URL(string: value)!), "Normal web navigation must stay available inside the browser")
        }
        for value in ["file:///private/data", "javascript:alert(1)", "data:text/html,hello", "hako://login", "tel:123", "mailto:test@example.com", "itms-services://?action=download-manifest", "about:blank", "https:/missing-host", "/relative", "https://user:password@example.com"] {
            let url = URL(string: value)!
            precondition(WorkshopBrowserLink(url: url) == nil, "Non-web links must not launch another app or access local files: \(value)")
            precondition(!WorkshopBrowserLink.allows(url), "Redirect and popup destinations use the same URL policy")
        }
        print("Workshop browser URL checks passed")
    }
}
