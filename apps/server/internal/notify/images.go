package notify

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"image"
	_ "image/gif"
	_ "image/jpeg"
	_ "image/png"
	"io"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"strings"
	"time"
)

const maxImage = 8 * 1024 * 1024

type imageSource struct {
	URL    *string `json:"url"`
	Base64 *string `json:"base64"`
}
type messageInput struct {
	Type  string       `json:"type"`
	Text  *string      `json:"text"`
	Image *imageSource `json:"image"`
}
type notification struct {
	kind, text, url, mime string
	data                  []byte
}

func (n notification) summary() string {
	if n.kind == "image" {
		return "[图片]"
	}
	return n.text
}
func (n notification) fingerprint() string {
	if n.kind == "text" {
		return sha([]byte(n.text))
	}
	if n.url != "" {
		return "image:" + sha([]byte("url:"+n.url))
	}
	return "image:" + sha(n.data)
}
func parseMessage(input messageInput) (notification, error) {
	if in(input.Type, "", "text") && input.Text != nil && input.Image == nil {
		text, err := validatedText(*input.Text, 4000)
		return notification{kind: "text", text: text}, err
	}
	if input.Type != "image" || input.Text != nil || input.Image == nil || (input.Image.URL == nil) == (input.Image.Base64 == nil) {
		return notification{}, invalid("图片 URL 和 Base64 必须且只能提供一个")
	}
	if input.Image.URL != nil {
		address, err := checkedImageURL(*input.Image.URL)
		if err != nil {
			return notification{}, err
		}
		return notification{kind: "image", url: address.String()}, nil
	}
	encoded := *input.Image.Base64
	if index := strings.IndexByte(encoded, ','); index >= 0 && in(strings.ToLower(encoded[:index]), "data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64") {
		encoded = encoded[index+1:]
	}
	encoded = strings.Join(strings.Fields(encoded), "")
	var data []byte
	var err error
	if strings.Contains(encoded, "=") {
		data, err = base64.StdEncoding.Strict().DecodeString(encoded)
	} else {
		data, err = base64.RawStdEncoding.Strict().DecodeString(encoded)
	}
	if err != nil || len(encoded) == 0 {
		return notification{}, problem(400, "INVALID_BASE64", "图片 Base64 格式不正确")
	}
	mime, err := validateImage(data)
	return notification{kind: "image", data: data, mime: mime}, err
}
func validateImage(data []byte) (string, error) {
	if len(data) == 0 {
		return "", problem(400, "EMPTY_IMAGE", "图片不能为空")
	}
	if len(data) > maxImage {
		return "", problem(413, "IMAGE_TOO_LARGE", "图片不能超过 8 MB")
	}
	cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		width, height := webpSize(data)
		if width == 0 || height == 0 {
			return "", problem(400, "INVALID_IMAGE", "图片无法识别，请提供 PNG、JPEG、GIF 或 WebP 图片")
		}
		cfg.Width, cfg.Height, format = width, height, "webp"
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || int64(cfg.Width)*int64(cfg.Height) > 40_000_000 {
		return "", problem(400, "IMAGE_DIMENSIONS", "图片尺寸无效或超过 4000 万像素")
	}
	return "image/" + format, nil
}
func webpSize(data []byte) (int, int) {
	if len(data) < 25 || string(data[:4]) != "RIFF" || string(data[8:12]) != "WEBP" {
		return 0, 0
	}
	size := int64(binary.LittleEndian.Uint32(data[4:8])) + 8
	chunk := int64(binary.LittleEndian.Uint32(data[16:20]))
	if size > int64(len(data)) || chunk+20 > size {
		return 0, 0
	}
	d := data[20 : 20+int(chunk)]
	switch string(data[12:16]) {
	case "VP8X":
		if len(d) >= 10 {
			le24 := func(x []byte) int { return int(x[0]) | int(x[1])<<8 | int(x[2])<<16 }
			return 1 + le24(d[4:7]), 1 + le24(d[7:10])
		}
	case "VP8L":
		if len(d) >= 5 && d[0] == 0x2f {
			bits := binary.LittleEndian.Uint32(d[1:5])
			return 1 + int(bits&0x3fff), 1 + int((bits>>14)&0x3fff)
		}
	case "VP8 ":
		if len(d) >= 10 && bytes.Equal(d[3:6], []byte{0x9d, 0x01, 0x2a}) {
			return int(binary.LittleEndian.Uint16(d[6:8]) & 0x3fff), int(binary.LittleEndian.Uint16(d[8:10]) & 0x3fff)
		}
	}
	return 0, 0
}

var blockedRanges = func() []netip.Prefix {
	addresses := strings.Fields("0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4 2001::/23 2001:db8::/32 2002::/16 3fff::/20")
	var ranges []netip.Prefix
	for _, address := range addresses {
		ranges = append(ranges, netip.MustParsePrefix(address))
	}
	return ranges
}()
var publicIPv6 = netip.MustParsePrefix("2000::/3")

func publicIP(address netip.Addr) bool {
	if !address.IsValid() || address.Zone() != "" || address.Is4In6() || !address.IsGlobalUnicast() {
		return false
	}
	if address.Is6() && !publicIPv6.Contains(address) {
		return false
	}
	for _, blocked := range blockedRanges {
		if blocked.Contains(address) {
			return false
		}
	}
	return true
}
func checkedImageURL(raw string) (*url.URL, error) {
	u, err := url.Parse(raw)
	if err != nil || len(raw) > 4096 || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return nil, problem(400, "INVALID_IMAGE_URL", "图片链接仅支持公网 HTTPS 地址")
	}
	host := strings.ToLower(strings.TrimSuffix(u.Hostname(), "."))
	ip, ipErr := netip.ParseAddr(host)
	if host == "localhost" || strings.HasSuffix(host, ".localhost") || (ipErr == nil && !publicIP(ip)) {
		return nil, problem(400, "INVALID_IMAGE_URL", "图片链接仅支持公网 HTTPS 地址")
	}
	u.Fragment = ""
	u.RawFragment = ""
	return u, nil
}
func downloadImage(ctx context.Context, address string) ([]byte, string, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	for redirect := 0; redirect <= 3; redirect++ {
		u, err := checkedImageURL(address)
		if err != nil {
			return nil, "", err
		}
		ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", u.Hostname())
		if err != nil || len(ips) == 0 {
			return nil, "", errors.New("图片域名解析失败")
		}
		var target netip.Addr
		for _, ip := range ips {
			// DNS results may represent IPv4 with an IPv6 mapped representation.
			ip = ip.Unmap()
			if !publicIP(ip) {
				return nil, "", problem(400, "PRIVATE_IMAGE_URL", "图片链接不能指向本机、内网或保留地址")
			}
			if !target.IsValid() || (!target.Is4() && ip.Is4()) {
				target = ip
			}
		}
		data, next, err := downloadImageAt(ctx, u, target)
		if err != nil {
			return nil, "", err
		}
		if next != "" {
			address = next
			continue
		}
		mime, err := validateImage(data)
		return data, mime, err
	}
	return nil, "", errors.New("图片重定向次数过多")
}
func downloadImageAt(ctx context.Context, u *url.URL, target netip.Addr) ([]byte, string, error) {
	client := noRedirectClient()
	transport := client.Transport.(*http.Transport)
	transport.Proxy = nil
	dialer := net.Dialer{}
	transport.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return dialer.DialContext(ctx, network, net.JoinHostPort(target.String(), "443"))
	}
	defer client.CloseIdleConnections()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return nil, "", err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, "", errors.New("图片下载失败或超时")
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		location, err := resp.Location()
		if err != nil {
			return nil, "", errors.New("图片重定向缺少有效地址")
		}
		return nil, location.String(), nil
	}
	if resp.StatusCode != 200 {
		return nil, "", errors.New("图片服务器拒绝请求")
	}
	if resp.ContentLength > maxImage {
		return nil, "", problem(413, "IMAGE_TOO_LARGE", "图片不能超过 8 MB")
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, maxImage+1))
	if err != nil {
		return nil, "", errors.New("图片下载失败或超时")
	}
	return data, "", nil
}
