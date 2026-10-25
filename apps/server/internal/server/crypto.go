package server

import (
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var raw64 = base64.RawURLEncoding
var errProofReplay = errors.New("replayed device proof")

func randomToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return raw64.EncodeToString(b)
}

func digest(s string) string { h := sha256.Sum256([]byte(s)); return raw64.EncodeToString(h[:]) }
func equal(a, b string) bool { return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1 }

type jwk struct {
	Crv string `json:"crv"`
	Kty string `json:"kty"`
	X   string `json:"x"`
	Y   string `json:"y"`
}

type proof struct {
	Thumb string
	JTI   string
	Nonce string
}

// RFC 9449: ES256 DPoP, RFC 7638 JWK thumbprint, exact public URL without query,
// method, bounded issuance time and ath for resource requests. JTI is consumed separately.
func verifyProof(r *http.Request, origin, access string, now time.Time) (proof, error) {
	fail := func() (proof, error) { return proof{}, fmt.Errorf("invalid device proof") }
	encoded := r.Header.Get("DPoP")
	if len(encoded) > 4096 {
		return fail()
	}
	parts := strings.Split(encoded, ".")
	if len(parts) != 3 {
		return fail()
	}
	var header struct {
		Typ string `json:"typ"`
		Alg string `json:"alg"`
		JWK jwk    `json:"jwk"`
	}
	var claims struct {
		HTM   string `json:"htm"`
		HTU   string `json:"htu"`
		IAT   int64  `json:"iat"`
		JTI   string `json:"jti"`
		ATH   string `json:"ath"`
		Nonce string `json:"nonce"`
	}
	hb, err := raw64.DecodeString(parts[0])
	if err != nil {
		return fail()
	}
	cb, err := raw64.DecodeString(parts[1])
	if err != nil {
		return fail()
	}
	if json.Unmarshal(hb, &header) != nil || json.Unmarshal(cb, &claims) != nil {
		return fail()
	}
	if header.Typ != "dpop+jwt" || header.Alg != "ES256" || header.JWK.Kty != "EC" || header.JWK.Crv != "P-256" {
		return fail()
	}
	if claims.HTM != r.Method || claims.HTU != origin+r.URL.EscapedPath() || claims.IAT < now.Unix()-60 || claims.IAT > now.Unix()+30 || len(claims.JTI) < 16 || len(claims.JTI) > 128 {
		return fail()
	}
	if access != "" && !equal(claims.ATH, digest(access)) {
		return fail()
	}
	x, err := raw64.DecodeString(header.JWK.X)
	if err != nil || len(x) != 32 {
		return fail()
	}
	y, err := raw64.DecodeString(header.JWK.Y)
	if err != nil || len(y) != 32 {
		return fail()
	}
	key := ecdsa.PublicKey{Curve: elliptic.P256(), X: new(big.Int).SetBytes(x), Y: new(big.Int).SetBytes(y)}
	if !key.Curve.IsOnCurve(key.X, key.Y) {
		return fail()
	}
	sig, err := raw64.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return fail()
	}
	hash := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(&key, hash[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])) {
		return fail()
	}
	canonical, _ := json.Marshal(header.JWK)
	return proof{Thumb: digest(string(canonical)), JTI: claims.JTI, Nonce: claims.Nonce}, nil
}

func consumeProof(st *state, p proof, now time.Time) error {
	for k, expires := range st.Proofs {
		if expires < now.Unix() {
			delete(st.Proofs, k)
		}
	}
	k := p.Thumb + ":" + p.JTI
	if _, exists := st.Proofs[k]; exists {
		return errProofReplay
	}
	if len(st.Proofs) >= 10000 {
		return fmt.Errorf("too many device proofs")
	}
	st.Proofs[k] = now.Unix() + 120
	return nil
}

func refreshToken(key []byte, sid string, generation int64) string {
	h := hmac.New(crypto.SHA256.New, key)
	h.Write([]byte("hako-refresh-v1:" + sid + ":" + strconv.FormatInt(generation, 10)))
	return raw64.EncodeToString(h.Sum(nil))
}
