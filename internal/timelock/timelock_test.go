package timelock

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)

const roundOne string = `{"round":1,"randomness":"1466a6cd24e327188770752f6134001c64d6efcc590ccc26b721611ad96f165a","signature":"b55e7cb2d5c613ee0b2e28d6750aabbb78c39dcc96bd9d38c2c2e12198df95571de8e8e402a0cc48871c7089a2b3af4b"}`

func testClient(t *testing.T, handler http.HandlerFunc) *Client {
	t.Helper()
	var server *httptest.Server = httptest.NewServer(handler)
	t.Cleanup(server.Close)
	var client *Client
	var err error
	client, err = newWithEndpoint(server.URL, server.Client())
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func available(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, roundOne) }

func TestRoundCeiling(t *testing.T) {
	for _, test := range []struct {
		epoch int64
		round uint64
	}{{0, 1}, {1692803367, 1}, {1692803368, 2}, {1692803370, 2}, {1692803371, 3}} {
		var got uint64 = Round(test.epoch)
		if got != test.round {
			t.Errorf("epoch %d: got %d, want %d", test.epoch, got, test.round)
		}
	}
}

func TestEncryptDecryptRoundTrip(t *testing.T) {
	var client *Client = testClient(t, available)
	var ciphertext []byte
	var err error
	ciphertext, err = client.Encrypt(context.Background(), []byte("a recovery secret\n"), 1)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(ciphertext, []byte("age-encryption.org/v1\n")) {
		t.Fatal("not tle-compatible binary age ciphertext")
	}
	var plaintext []byte
	plaintext, err = client.Decrypt(context.Background(), ciphertext)
	if err != nil {
		t.Fatal(err)
	}
	if string(plaintext) != "a recovery secret\n" {
		t.Errorf("got %q", plaintext)
	}
}

func TestDecryptTleFixtures(t *testing.T) {
	var client *Client = testClient(t, available)
	for _, name := range []string{"tle-v1.2.0-round-1.age", "tle-v1.2.0-round-1.armored.age"} {
		var ciphertext []byte
		var err error
		ciphertext, err = os.ReadFile("testdata/" + name)
		if err != nil {
			t.Fatal(err)
		}
		var plaintext []byte
		plaintext, err = client.Decrypt(context.Background(), ciphertext)
		if err != nil {
			t.Fatal(err)
		}
		if string(plaintext) != "vaultlock tle compatibility fixture" {
			t.Fatalf("%s: got %q", name, plaintext)
		}
	}
}

func TestVerifyFutureUsesBeaconAndValidatesHeader(t *testing.T) {
	var requests int
	var client *Client = testClient(t, func(w http.ResponseWriter, r *http.Request) {
		requests++
		if strings.HasSuffix(r.URL.Path, "/latest") {
			fmt.Fprint(w, roundOne)
			return
		}
		http.Error(w, "not found", http.StatusNotFound)
	})
	var ciphertext []byte
	var err error
	ciphertext, err = client.Encrypt(context.Background(), []byte("secret"), 2)
	if err != nil {
		t.Fatal(err)
	}
	if err = client.VerifyFuture(context.Background(), ciphertext, 2); err != nil {
		t.Fatal(err)
	}
	if requests < 2 {
		t.Fatal("future verification did not consult the beacon")
	}
	if _, err = client.Decrypt(context.Background(), ciphertext); !errors.Is(err, ErrTooEarly) {
		t.Fatalf("got %v", err)
	}
	for _, test := range []struct {
		name       string
		ciphertext []byte
		round      uint64
	}{
		{"wrong round", ciphertext, 3},
		{"wrong chain", bytes.Replace(ciphertext, []byte(ChainHash), bytes.Repeat([]byte("0"), 64), 1), 2},
		{"garbage", []byte("invalid ciphertext"), 2},
		{"truncated", ciphertext[:30], 2},
		{"truncated payload", ciphertext[:len(ciphertext)-25], 2},
	} {
		t.Run(test.name, func(t *testing.T) {
			var err error = client.VerifyFuture(context.Background(), test.ciphertext, test.round)
			if err == nil || errors.Is(err, ErrTooEarly) {
				t.Fatalf("accepted invalid ciphertext: %v", err)
			}
		})
	}
}

func TestFutureHTTP425(t *testing.T) {
	var client *Client = testClient(t, func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/latest") {
			fmt.Fprint(w, roundOne)
			return
		}
		http.Error(w, "too early", http.StatusTooEarly)
	})
	var ciphertext []byte
	var err error
	ciphertext, err = client.Encrypt(context.Background(), []byte("secret"), 2)
	if err != nil {
		t.Fatal(err)
	}
	if err = client.VerifyFuture(context.Background(), ciphertext, 2); err != nil {
		t.Fatal(err)
	}
}

func TestNetworkFailureIsNotTooEarly(t *testing.T) {
	for _, test := range []struct {
		name     string
		status   int
		response string
	}{
		{"unavailable", 500, "offline"},
		{"invalid JSON", 200, "invalid"},
		{"invalid signature", 200, `{"round":1,"signature":"00"}`},
		{"wrong round", 200, `{"round":2,"signature":"00"}`},
		{"no future proof", 404, "not found"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var client *Client = testClient(t, func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(test.status); fmt.Fprint(w, test.response) })
			var ciphertext []byte
			var err error
			ciphertext, err = client.Encrypt(context.Background(), []byte("secret"), 1)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = client.Decrypt(context.Background(), ciphertext); err == nil || errors.Is(err, ErrTooEarly) {
				t.Fatalf("network failure classified as future: %v", err)
			}
		})
	}
}

func TestRejectsAlreadyDecryptableCiphertext(t *testing.T) {
	var client *Client = testClient(t, available)
	var ciphertext []byte
	var err error
	ciphertext, err = client.Encrypt(context.Background(), []byte("secret"), 1)
	if err != nil {
		t.Fatal(err)
	}
	if err = client.VerifyFuture(context.Background(), ciphertext, 1); err == nil {
		t.Fatal("accepted decryptable ciphertext")
	}
	var cancelled context.Context
	var cancel context.CancelFunc
	cancelled, cancel = context.WithCancel(context.Background())
	cancel()
	if _, err = client.Decrypt(cancelled, ciphertext); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	if _, err = client.Encrypt(cancelled, []byte("secret"), 2); !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v", err)
	}
	if _, err = client.Encrypt(context.Background(), []byte("secret"), 0); err == nil {
		t.Fatal("accepted zero round")
	}
}

func TestDecryptHonoursCancellationDuringRequest(t *testing.T) {
	var client *Client = testClient(t, func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() })
	var ciphertext []byte
	var err error
	ciphertext, err = client.Encrypt(context.Background(), []byte("secret"), 1)
	if err != nil {
		t.Fatal(err)
	}
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err = client.Decrypt(ctx, ciphertext); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("got %v", err)
	}
}

func TestLiveQuicknet(t *testing.T) {
	if os.Getenv("VAULTLOCK_LIVE_DRAND") != "1" {
		t.Skip("set VAULTLOCK_LIVE_DRAND=1 for live Quicknet compatibility")
	}
	var client *Client
	var err error
	client, err = New()
	if err != nil {
		t.Fatal(err)
	}
	var ctx context.Context
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var old, future []byte
	old, err = client.Encrypt(ctx, []byte("live smoke"), 1)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = client.Decrypt(ctx, old); err != nil {
		t.Fatal(err)
	}
	var round uint64 = Round(time.Now().Add(time.Hour).Unix())
	future, err = client.Encrypt(ctx, []byte("live future"), round)
	if err != nil {
		t.Fatal(err)
	}
	if err = client.VerifyFuture(ctx, future, round); err != nil {
		t.Fatal(err)
	}
}
