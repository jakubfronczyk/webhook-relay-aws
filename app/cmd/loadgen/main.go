// Command loadgen drives POST /events through a rate profile and writes one CSV row per
// second: accept latency next to queue backlog and worker task count, on one time axis.
// Not part of the system.
//
//	loadgen -target http://<alb> -profile 10:30s,1000:5s,10:60s \
//	        -queue-url <url> -cluster webhook-relay -service webhook-relay-worker > run.csv
package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ecs"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// stage is one segment of the profile: a constant rate held for a duration.
type stage struct {
	rate int
	dur  time.Duration
}

type result struct {
	latency time.Duration
	ok      bool
}

// gauges are sampled by a separate poller, so a slow AWS call never delays a CSV row.
type gauges struct {
	visible, inFlight, tasks atomic.Int64
}

func main() {
	target := flag.String("target", "", "api base URL, e.g. http://<alb_dns_name>")
	eventType := flag.String("type", "load.test", "event type to publish; subscribe the sink to it first")
	profileFlag := flag.String("profile", "10:30s,1000:5s,10:60s", "comma-separated rate:duration stages")
	workers := flag.Int("workers", 256, "maximum requests in flight")
	queueURL := flag.String("queue-url", "", "delivery queue, sampled for backlog when set")
	cluster := flag.String("cluster", "", "ECS cluster, sampled for worker task count with -service")
	service := flag.String("service", "", "ECS service whose running count is sampled")
	drainTimeout := flag.Duration("drain-timeout", 15*time.Minute, "how long to keep sampling after the last event while the backlog drains")
	flag.Parse()

	if *target == "" {
		log.Fatal("-target is required")
	}
	profile, err := parseProfile(*profileFlag)
	if err != nil {
		log.Fatal(err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	g := &gauges{}
	for _, v := range []*atomic.Int64{&g.visible, &g.inFlight, &g.tasks} {
		v.Store(-1)
	}
	sampling := *queueURL != "" || (*cluster != "" && *service != "")
	if sampling {
		if err := startPoller(ctx, g, *queueURL, *cluster, *service); err != nil {
			log.Fatal(err)
		}
	}

	results := make(chan result, *workers)
	var rate atomic.Int64
	done := make(chan struct{})
	go func() {
		record(ctx, results, &rate, g, sampling, *drainTimeout)
		close(done)
	}()

	send(ctx, *target, *eventType, profile, *workers, results, &rate)
	close(results)
	<-done
}

func parseProfile(s string) ([]stage, error) {
	var out []stage
	for _, part := range strings.Split(s, ",") {
		r, d, ok := strings.Cut(strings.TrimSpace(part), ":")
		rate, err1 := strconv.Atoi(r)
		dur, err2 := time.ParseDuration(d)
		if !ok || err1 != nil || err2 != nil || rate < 1 || dur <= 0 {
			return nil, fmt.Errorf("bad stage %q, want rate:duration like 100:30s", part)
		}
		out = append(out, stage{rate, dur})
	}
	return out, nil
}

// send is open-loop: each event is scheduled at start + i/rate, so a slow response
// delays nothing after it until every worker slot is taken.
func send(ctx context.Context, target, eventType string, profile []stage, workers int, results chan<- result, rate *atomic.Int64) {
	client := &http.Client{
		Timeout:   10 * time.Second,
		Transport: &http.Transport{MaxIdleConnsPerHost: workers},
	}
	url := strings.TrimSuffix(target, "/") + "/events"
	body := []byte(fmt.Sprintf(`{"type":%q,"payload":{"source":"loadgen"}}`, eventType))

	sem := make(chan struct{}, workers)
	var wg sync.WaitGroup
	defer wg.Wait()

	for _, st := range profile {
		rate.Store(int64(st.rate))
		start := time.Now()
		n := int(float64(st.rate) * st.dur.Seconds())
		for i := range n {
			next := start.Add(time.Duration(float64(i) / float64(st.rate) * float64(time.Second)))
			select {
			case <-ctx.Done():
				return
			case <-time.After(time.Until(next)):
			}
			sem <- struct{}{}
			wg.Add(1)
			go func() {
				defer wg.Done()
				defer func() { <-sem }()
				results <- post(ctx, client, url, body)
			}()
		}
	}
}

func post(ctx context.Context, client *http.Client, url string, body []byte) result {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return result{}
	}
	req.Header.Set("Content-Type", "application/json")
	start := time.Now()
	resp, err := client.Do(req)
	lat := time.Since(start)
	if err != nil {
		return result{latency: lat}
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()
	return result{latency: lat, ok: resp.StatusCode == http.StatusAccepted}
}

// record writes one CSV row per second until sending has finished and, when sampling,
// the backlog has drained or the drain timeout has passed.
func record(ctx context.Context, results <-chan result, rate *atomic.Int64, g *gauges, sampling bool, drainTimeout time.Duration) {
	w := csv.NewWriter(os.Stdout)
	_ = w.Write([]string{"t_s", "target_rate", "sent", "accepted", "errors", "p50_ms", "p99_ms", "max_ms", "visible", "in_flight", "worker_tasks"})

	var (
		begin           = time.Now()
		tick            = time.NewTicker(time.Second)
		window, all     []time.Duration
		sent, acc, errs int
		total, totalAcc int
		peakBacklog     = int64(-1)
		peakTasks       = int64(-1)
		sendEnd         time.Time
		drainedAt       time.Duration
		resultsOpen     = true
	)
	defer tick.Stop()

	flush := func() {
		ms := func(p float64) string { return fmt.Sprintf("%.1f", float64(percentile(window, p).Microseconds())/1000) }
		t := int(time.Since(begin).Round(time.Second).Seconds())
		_ = w.Write([]string{
			strconv.Itoa(t), strconv.FormatInt(rate.Load(), 10),
			strconv.Itoa(sent), strconv.Itoa(acc), strconv.Itoa(errs),
			ms(0.50), ms(0.99), ms(1),
			strconv.FormatInt(g.visible.Load(), 10), strconv.FormatInt(g.inFlight.Load(), 10),
			strconv.FormatInt(g.tasks.Load(), 10),
		})
		w.Flush()
		all = append(all, window...)
		total, totalAcc = total+sent, totalAcc+acc
		window, sent, acc, errs = nil, 0, 0, 0
	}

	for {
		select {
		case r, ok := <-results:
			if !ok {
				resultsOpen = false
				results = nil
				sendEnd = time.Now()
				rate.Store(0)
				continue
			}
			sent++
			window = append(window, r.latency)
			if r.ok {
				acc++
			} else {
				errs++
			}
		case <-tick.C:
			flush()
			backlog := g.visible.Load() + g.inFlight.Load()
			if sampling {
				peakBacklog = max(peakBacklog, backlog)
				peakTasks = max(peakTasks, g.tasks.Load())
			}
			if resultsOpen {
				continue
			}
			if !sampling {
				summarize(all, total, totalAcc, peakBacklog, peakTasks, 0)
				return
			}
			if backlog == 0 {
				drainedAt = time.Since(sendEnd)
				summarize(all, total, totalAcc, peakBacklog, peakTasks, drainedAt)
				return
			}
			if time.Since(sendEnd) > drainTimeout {
				log.Printf("backlog %d after the %s drain timeout", backlog, drainTimeout)
				summarize(all, total, totalAcc, peakBacklog, peakTasks, 0)
				return
			}
		case <-ctx.Done():
			flush()
			summarize(all, total, totalAcc, peakBacklog, peakTasks, 0)
			return
		}
	}
}

func summarize(all []time.Duration, total, accepted int, peakBacklog, peakTasks int64, drained time.Duration) {
	f := func(p float64) float64 { return float64(percentile(all, p).Microseconds()) / 1000 }
	fmt.Fprintf(os.Stderr, "\nsent %d, accepted %d, failed %d\n", total, accepted, total-accepted)
	fmt.Fprintf(os.Stderr, "accept latency  p50 %.1fms  p99 %.1fms  max %.1fms\n", f(0.50), f(0.99), f(1))
	if peakBacklog >= 0 {
		fmt.Fprintf(os.Stderr, "peak backlog %d\n", peakBacklog)
	}
	if peakTasks >= 0 {
		fmt.Fprintf(os.Stderr, "peak worker tasks %d\n", peakTasks)
	}
	if drained > 0 {
		fmt.Fprintf(os.Stderr, "drained %s after the last event\n", drained.Round(time.Second))
	}
}

func percentile(d []time.Duration, p float64) time.Duration {
	if len(d) == 0 {
		return 0
	}
	s := slices.Clone(d)
	slices.Sort(s)
	return s[min(len(s)-1, int(p*float64(len(s))))]
}

// startPoller samples the queue and the service once a second. One attribute per
// call keeps an ElasticMQ quirk out of the numbers, and both counts are approximate.
func startPoller(ctx context.Context, g *gauges, queueURL, cluster, service string) error {
	cfg, err := awsconfig.LoadDefaultConfig(ctx)
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}
	q, e := sqs.NewFromConfig(cfg), ecs.NewFromConfig(cfg)

	attr := func(name types.QueueAttributeName) (int64, error) {
		out, err := q.GetQueueAttributes(ctx, &sqs.GetQueueAttributesInput{
			QueueUrl: &queueURL, AttributeNames: []types.QueueAttributeName{name},
		})
		if err != nil {
			return 0, err
		}
		return strconv.ParseInt(out.Attributes[string(name)], 10, 64)
	}

	poll := func() error {
		if queueURL != "" {
			v, err := attr(types.QueueAttributeNameApproximateNumberOfMessages)
			if err != nil {
				return err
			}
			f, err := attr(types.QueueAttributeNameApproximateNumberOfMessagesNotVisible)
			if err != nil {
				return err
			}
			g.visible.Store(v)
			g.inFlight.Store(f)
		}
		if cluster != "" && service != "" {
			out, err := e.DescribeServices(ctx, &ecs.DescribeServicesInput{
				Cluster: &cluster, Services: []string{service},
			})
			if err != nil {
				return err
			}
			if len(out.Services) == 0 {
				return errors.New("service not found: " + service)
			}
			g.tasks.Store(int64(out.Services[0].RunningCount))
		}
		return nil
	}

	// Fail fast on a wrong URL or missing permission rather than writing a CSV of -1s.
	if err := poll(); err != nil {
		return err
	}
	go func() {
		t := time.NewTicker(time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if err := poll(); err != nil && ctx.Err() == nil {
					log.Printf("sample: %v", err)
				}
			}
		}
	}()
	return nil
}
