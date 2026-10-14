// A real load generator for one Nakama cell: goroutines + a connection pool, no external deps.
//
//	go run scripts/bench-load.go -api http://127.0.0.1:20350 -op auth -conc 50 -dur 8s
//
// It runs for a fixed duration at a fixed concurrency (not N requests), so it finds the cell's
// breaking point instead of measuring the generator itself.
package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	api := flag.String("api", "http://127.0.0.1:20350", "cell address")
	op := flag.String("op", "auth", "auth | get")
	conc := flag.Int("conc", 50, "number of concurrent workers")
	dur := flag.Duration("dur", 8*time.Second, "measurement duration")
	flag.Parse()

	tr := &http.Transport{MaxIdleConns: 4096, MaxIdleConnsPerHost: 4096, MaxConnsPerHost: 0}
	cl := &http.Client{Transport: tr, Timeout: 30 * time.Second}
	basic := "Basic " + base64.StdEncoding.EncodeToString([]byte("defaultkey:"))

	// warmup: fetch a token + user_id
	body := []byte(`{"id":"loadgen-device"}`)
	req, _ := http.NewRequest("POST", *api+"/v2/account/authenticate/device?create=true", bytes.NewReader(body))
	req.Header.Set("Authorization", basic)
	req.Header.Set("Content-Type", "application/json")
	resp, err := cl.Do(req)
	if err != nil {
		fmt.Println("cell did not answer:", err)
		return
	}
	var session struct {
		Token string `json:"token"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&session)
	resp.Body.Close()
	if session.Token == "" {
		fmt.Println("could not get a token")
		return
	}
	greq, _ := http.NewRequest("GET", *api+"/v2/account", nil)
	greq.Header.Set("Authorization", "Bearer "+session.Token)
	resp, _ = cl.Do(greq)
	var acct struct {
		User struct {
			ID string `json:"id"`
		} `json:"user"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&acct)
	resp.Body.Close()

	var lats []time.Duration
	var mu sync.Mutex
	var okCount, errCount int64
	errs := map[string]int64{}
	stop := time.Now().Add(*dur)
	var wg sync.WaitGroup
	for i := 0; i < *conc; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for time.Now().Before(stop) {
				var r *http.Request
				if *op == "auth" {
					r, _ = http.NewRequest("POST", *api+"/v2/account/authenticate/device?create=true", bytes.NewReader(body))
					r.Header.Set("Authorization", basic)
					r.Header.Set("Content-Type", "application/json")
				} else {
					r, _ = http.NewRequest("GET", *api+"/v2/storage/load?user_id="+acct.User.ID, nil)
					r.Header.Set("Authorization", "Bearer "+session.Token)
				}
				t0 := time.Now()
				resp, err := cl.Do(r)
				d := time.Since(t0)
				msg := ""
				if err != nil {
					msg = "transport"
				} else {
					io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					if resp.StatusCode != 200 {
						msg = fmt.Sprintf("HTTP %d", resp.StatusCode)
					}
				}
				if msg == "" {
					atomic.AddInt64(&okCount, 1)
					mu.Lock()
					lats = append(lats, d)
					mu.Unlock()
				} else {
					atomic.AddInt64(&errCount, 1)
					mu.Lock()
					errs[msg]++
					mu.Unlock()
				}
			}
		}()
	}
	t0 := time.Now()
	wg.Wait()
	wall := time.Since(t0)

	sort.Slice(lats, func(i, j int) bool { return lats[i] < lats[j] })
	p := func(q float64) float64 {
		if len(lats) == 0 {
			return 0
		}
		return float64(lats[int(q*float64(len(lats)-1))].Microseconds()) / 1000
	}
	fmt.Printf("  %-6s conc=%-4d  %8.0f req/s   p50=%7.1fms p95=%7.1fms p99=%7.1fms   ok=%d err=%d %v\n",
		*op, *conc, float64(okCount)/wall.Seconds(), p(.5), p(.95), p(.99), okCount, errCount, errs)
}
