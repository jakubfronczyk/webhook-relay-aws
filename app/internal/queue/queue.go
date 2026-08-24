// Package queue wraps the delivery queue. ElasticMQ speaks the SQS wire
// protocol, so only the endpoint URL differs between a laptop and Fargate.
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

// Delivery is the message body. It carries ids only; the event itself is
// already durable in Postgres.
type Delivery struct {
	EventID   string `json:"event_id"`
	EventType string `json:"event_type"`
}

// Message is a received Delivery plus the receipt handle to ack with and the
// receive count the backoff curve is derived from.
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
		// ElasticMQ verifies nothing, but the SDK refuses to sign without credentials.
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

// Send is called after the event row exists; a message referencing a missing
// event is unresolvable by any retry.
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

// Receive long-polls; short polling bills a request per task every few
// milliseconds on an idle fleet.
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
			// Unparseable, and no retry fixes it; maxReceiveCount carries it to the DLQ.
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

// Delete acks the message, and runs only once every subscriber has been dealt
// with. A worker killed before this call causes redelivery, never loss.
func (q *Queue) Delete(ctx context.Context, receiptHandle string) error {
	_, err := q.client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
		QueueUrl:      aws.String(q.url),
		ReceiptHandle: aws.String(receiptHandle),
	})
	return err
}

// Retry sets a new visibility timeout on this receipt. SQS has no exponential
// backoff setting, so the growing interval is applied per message here.
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
