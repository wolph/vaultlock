// Package timelock embeds the same age/tlock implementation used by tle.
package timelock

import (
	"bufio"
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"filippo.io/age"
	"filippo.io/age/armor"
	chain "github.com/drand/drand/v2/common"
	"github.com/drand/drand/v2/crypto"
	"github.com/drand/kyber"
	"github.com/drand/tlock"
)

const (
	ChainHash         string        = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971"
	Genesis           int64         = 1692803367
	Period            int64         = 3
	quicknetPublicKey string        = "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d1064510d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a"
	defaultEndpoint   string        = "https://api.drand.sh"
	networkTimeout    time.Duration = 10 * time.Second
)

// ErrTooEarly means a valid signed beacon confirms the requested round is later.
var ErrTooEarly error = errors.New("too early to decrypt")

// Client pins the Quicknet scheme and public key. Construction needs no network.
type Client struct {
	endpoint  string
	http      *http.Client
	publicKey kyber.Point
	scheme    crypto.Scheme
}

func New() (*Client, error) {
	return newWithEndpoint(defaultEndpoint, &http.Client{Timeout: networkTimeout})
}

func newWithEndpoint(endpoint string, transport *http.Client) (*Client, error) {
	var scheme *crypto.Scheme
	var err error
	scheme, err = crypto.SchemeFromName(crypto.SigsOnG1ID)
	if err != nil {
		return nil, err
	}
	var key []byte
	key, err = hex.DecodeString(quicknetPublicKey)
	if err != nil {
		return nil, err
	}
	var publicKey kyber.Point = scheme.KeyGroup.Point()
	if err = publicKey.UnmarshalBinary(key); err != nil {
		return nil, err
	}
	return &Client{endpoint: strings.TrimRight(endpoint, "/"), http: transport, publicKey: publicKey, scheme: *scheme}, nil
}

// Round returns the first round whose beacon time is at or after epoch.
func Round(epoch int64) uint64 {
	if epoch <= Genesis {
		return 1
	}
	var delta int64 = epoch - Genesis
	return uint64(delta/Period) + 1 + uint64((delta%Period+Period-1)/Period)
}

func (c *Client) Encrypt(ctx context.Context, plaintext []byte, round uint64) ([]byte, error) {
	var err error = ctx.Err()
	if err != nil {
		return nil, err
	}
	if round == 0 {
		return nil, errors.New("drand round must be positive")
	}
	var network *network = c.network(ctx)
	var ciphertext bytes.Buffer
	if err = tlock.New(network).Strict().Encrypt(&ciphertext, bytes.NewReader(plaintext), round); err != nil {
		return nil, err
	}
	return ciphertext.Bytes(), nil
}

func (c *Client) Decrypt(ctx context.Context, ciphertext []byte) ([]byte, error) {
	var err error = ctx.Err()
	if err != nil {
		return nil, err
	}
	if _, err = c.inspect(ciphertext); err != nil {
		return nil, err
	}
	var network *network = c.network(ctx)
	var plaintext bytes.Buffer
	err = tlock.New(network).Strict().Decrypt(&plaintext, bytes.NewReader(ciphertext))
	// tlock labels every Signature failure as too early. Preserve transport and
	// validation failures so an outage cannot satisfy future verification.
	if network.signatureError != nil {
		return nil, network.signatureError
	}
	if err != nil {
		return nil, err
	}
	return plaintext.Bytes(), nil
}

func (c *Client) VerifyFuture(ctx context.Context, ciphertext []byte, round uint64) error {
	var actual uint64
	var err error
	actual, err = c.inspect(ciphertext)
	if err != nil {
		return err
	}
	if actual != round {
		return fmt.Errorf("ciphertext round %d does not match expected round %d", actual, round)
	}
	if _, err = c.Decrypt(ctx, ciphertext); errors.Is(err, ErrTooEarly) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("cannot verify future ciphertext: %w", err)
	}
	return errors.New("ciphertext is already decryptable")
}

var errInspected error = errors.New("ciphertext header inspected")

type headerIdentity struct{ stanzas []*age.Stanza }

func (h *headerIdentity) Unwrap(stanzas []*age.Stanza) ([]byte, error) {
	h.stanzas = stanzas
	return nil, errInspected
}

func (c *Client) inspect(ciphertext []byte) (uint64, error) {
	var err error
	if bytes.HasPrefix(ciphertext, []byte(armor.Header)) {
		ciphertext, err = io.ReadAll(armor.NewReader(bytes.NewReader(ciphertext)))
		if err != nil {
			return 0, fmt.Errorf("invalid ciphertext armour: %w", err)
		}
	}
	var reader *bufio.Reader = bufio.NewReader(bytes.NewReader(ciphertext))
	var identity headerIdentity
	_, err = age.Decrypt(reader, &identity)
	if !errors.Is(err, errInspected) {
		return 0, fmt.Errorf("invalid time-lock header: %w", err)
	}
	if len(identity.stanzas) != 1 {
		return 0, errors.New("ciphertext must have exactly one time-lock recipient")
	}
	var stanza *age.Stanza = identity.stanzas[0]
	if stanza.Type != "tlock" || len(stanza.Args) != 2 || stanza.Args[1] != ChainHash {
		return 0, errors.New("ciphertext does not use pinned Quicknet chain")
	}
	var round uint64
	round, err = strconv.ParseUint(stanza.Args[0], 10, 64)
	if err != nil || round == 0 {
		return 0, errors.New("invalid ciphertext round")
	}
	if _, err = tlock.BytesToCiphertext(c.scheme, stanza.Body); err != nil {
		return 0, fmt.Errorf("invalid time-lock recipient: %w", err)
	}
	// age cannot authenticate a future ciphertext yet, but the cleartext format
	// must include its header MAC, 16-byte stream nonce and final 16-byte tag.
	var macOffset int = bytes.Index(ciphertext, []byte("\n--- "))
	if macOffset < 0 {
		return 0, errors.New("ciphertext has no header MAC")
	}
	var lineEnd int = bytes.IndexByte(ciphertext[macOffset+1:], '\n')
	if lineEnd < 0 || len(ciphertext)-(macOffset+lineEnd+2) < 32 {
		return 0, errors.New("ciphertext payload is truncated")
	}
	return round, nil
}

func (c *Client) network(ctx context.Context) *network { return &network{client: c, ctx: ctx} }

type network struct {
	client         *Client
	ctx            context.Context
	signatureError error
}

func (n *network) ChainHash() string { return ChainHash }
func (n *network) Current(now time.Time) uint64 {
	if now.Unix() < Genesis {
		return 0
	}
	return uint64((now.Unix()-Genesis)/Period) + 1
}
func (n *network) PublicKey() kyber.Point       { return n.client.publicKey.Clone() }
func (n *network) Scheme() crypto.Scheme        { return n.client.scheme }
func (n *network) SwitchChainHash(string) error { return errors.New("Quicknet chain is pinned") }

type beaconResponse struct {
	Round     uint64 `json:"round"`
	Signature string `json:"signature"`
}

func (n *network) Signature(round uint64) ([]byte, error) {
	var result beaconResponse
	var status int
	var err error
	result, status, err = n.fetch(strconv.FormatUint(round, 10))
	if err == nil && (status == http.StatusNotFound || status == http.StatusTooEarly) {
		result, _, err = n.fetch("latest")
		if err == nil {
			_, err = n.verify(result)
			if err == nil && result.Round < round {
				err = ErrTooEarly
			}
			if err == nil {
				err = errors.New("requested drand beacon is missing although its round has passed")
			}
		}
	} else if err == nil && result.Round != round {
		err = errors.New("drand returned the wrong beacon round")
	}
	if err != nil {
		n.signatureError = err
		return nil, err
	}
	var signature []byte
	signature, err = n.verify(result)
	if err != nil {
		n.signatureError = err
	}
	return signature, err
}

func (n *network) verify(result beaconResponse) ([]byte, error) {
	if result.Round == 0 {
		return nil, errors.New("drand beacon has no round")
	}
	var signature []byte
	var err error
	signature, err = hex.DecodeString(result.Signature)
	if err != nil {
		return nil, fmt.Errorf("invalid drand signature encoding: %w", err)
	}
	var beacon chain.Beacon = chain.Beacon{Round: result.Round, Signature: signature}
	if err = n.client.scheme.VerifyBeacon(&beacon, n.PublicKey()); err != nil {
		return nil, fmt.Errorf("invalid drand beacon signature: %w", err)
	}
	return signature, nil
}

func (n *network) fetch(round string) (beaconResponse, int, error) {
	var result beaconResponse
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(n.ctx, networkTimeout)
	defer cancel()
	var request *http.Request
	var err error
	request, err = http.NewRequestWithContext(ctx, http.MethodGet, n.client.endpoint+"/"+ChainHash+"/public/"+round, nil)
	if err != nil {
		return result, 0, err
	}
	var response *http.Response
	response, err = n.client.http.Do(request)
	if err != nil {
		return result, 0, fmt.Errorf("fetch drand beacon: %w", err)
	}
	defer response.Body.Close()
	if (response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusTooEarly) && round != "latest" {
		return result, response.StatusCode, nil
	}
	if response.StatusCode != http.StatusOK {
		return result, response.StatusCode, fmt.Errorf("drand returned HTTP %d", response.StatusCode)
	}
	var body []byte
	body, err = io.ReadAll(io.LimitReader(response.Body, 64*1024+1))
	if err != nil {
		return result, response.StatusCode, err
	}
	if len(body) > 64*1024 {
		return result, response.StatusCode, errors.New("drand response exceeds limit")
	}
	if err = json.Unmarshal(body, &result); err != nil {
		return result, response.StatusCode, fmt.Errorf("decode drand beacon: %w", err)
	}
	return result, response.StatusCode, nil
}
