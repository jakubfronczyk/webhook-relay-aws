// Package queue wraps the one SQS queue this system has.
//
// There is a single SQS client implementation for both environments. ElasticMQ
// speaks the SQS wire protocol, so the only thing that changes between a laptop
// and Fargate is the endpoint URL. That is the whole reason Phase 2 does not use
// a Go channel: a channel has no visibility timeout, no receive count, and no
// dead-letter queue, so a local demo built on one would exercise a code path
// that does not exist in AWS.
package queue

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"github.com/aws/aws-sdk-go-v2/service/sqs/types"
)

// Delivery is the message body. It carries ids only, never the payload:
// the event is already durable in Postgres, and a 256KB SQS body limit is not
// a limit worth inheriting.
type Delivery struct {
	EventID   string `json:"event_id"`
	EventType string `json:"event_type"`
}

// Message is a received Delivery plus the two pieces of SQS bookkeeping the
// worker needs: the handle to ack with, and how many times this message has
// been received. The receive count is what the backoff curve is derived from.
type Message struct {
	Delivery
	ReceiptHandle string
	ReceiveCount  int
}

type Queue struct {
	client *sqs.Client
	url    string
}

func Open(ctx context.Context, region, endpoint, queueURL string) (*Queue, error) {
	if queueURL == "" {
		return nil, fmt.Errorf("QUEUE_URL is required")
	}

	opts := []func(*awsconfig.LoadOptions) error{awsconfig.WithRegion(region)}
	if endpoint != "" {
		// ElasticMQ authenticates nothing but the SDK refuses to sign without
		// credentials, so supply throwaway ones rather than a no-op signer.
		opts = append(opts, awsconfig.WithCredentialsProvider(
			credentials.NewStaticCredentialsProvider("local", "local", "")))
	}

	cfg, err := awsconfig.LoadDefaultConfig(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	client := sqs.NewFromConfig(cfg, func(o *sqs.Options) {
		if endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
	})
	return &Queue{client: client, url: queueURL}, nil
}

// Send is the api's only queue operation, and it happens after the INSERT.
// Order matters: an event in the queue but not in the database is a message the
// worker cannot resolve, while an event in the database but not in the queue is
// a row a human can requeue.
func (q *Queue) Send(ctx context.Context, d Delivery) error {
	body, err := json.Marshal(d)
	if err != nil {
		return err
	}
	_, err = q.client.SendMessage(ctx, &sqs.SendMessageInput{
		QueueUrl:    aws.String(q.url),
		MessageBody: aws.String(string(body)),
	})
	return err
}

// Receive long-polls. Long polling is not a tuning knob here: with short polls
// an idle fleet bills a request per task per few milliseconds, and the backlog
// metric the worker autoscales on gets noisier for no benefit.
func (q *Queue) Receive(ctx context.Context, batch, waitSeconds int32) ([]Message, error) {
	out, err := q.client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl:            aws.String(q.url),
		MaxNumberOfMessages: batch,
		WaitTimeSeconds:     waitSeconds,
		MessageSystemAttributeNames: []types.MessageSystemAttributeName{
			types.MessageSystemAttributeNameApproximateReceiveCount,
		},
	})
	if err != nil {
		return nil, err
	}

	msgs := make([]Message, 0, len(out.Messages))
	for _, m := range out.Messages {
		var d Delivery
		if err := json.Unmarshal([]byte(aws.ToString(m.Body)), &d); err != nil {
			// Unparseable body: nothing a retry fixes. Let maxReceiveCount
			// carry it to the DLQ rather than deleting evidence.
			continue
		}
		msgs = append(msgs, Message{
			Delivery:      d,
			ReceiptHandle: aws.ToString(m.ReceiptHandle),
			ReceiveCount:  attrInt(m.Attributes, string(types.MessageSystemAttributeNameApproximateReceiveCount)),
		})
	}
	return msgs, nil
}

// Delete is the ack. It runs only after every subscriber for the event has been
// dealt with, which is what makes the pipeline at-least-once: a worker killed
// between the POST and this call means the message reappears and is delivered
// again, never that it is lost.
func (q *Queue) Delete(ctx context.Context, receiptHandle string) error {
	_, err := q.client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(q.url),
		ReceiptHandle: aws.String(receiptHandle),
	})
	return err
}

// Retry hands the message back early with a new visibility timeout. This is the
// backoff curve: SQS has no exponential retry setting, only one fixed
// visibility timeout, so the growing interval is ours to apply per message.
func (q *Queue) Retry(ctx context.Context, receiptHandle string, after time.Duration) error {
	_, err := q.client.ChangeMessageVisibility(ctx, &sqs.ChangeMessageVisibilityInput{
		QueueUrl:          aws.String(q.url),
		ReceiptHandle:     aws.String(receiptHandle),
		VisibilityTimeout: int32(after.Seconds()),
	})
	return err
}

func attrInt(attrs map[string]string, key string) int {
	n := 0
	for _, c := range attrs[key] {
		if c < '0' || c > '9' {
			return n
		}
		n = n*10 + int(c-'0')
	}
	return n
}
