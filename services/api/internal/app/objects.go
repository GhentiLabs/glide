package app

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"github.com/GhentiLabs/glide/services/api/internal/config"
	"github.com/GhentiLabs/glide/services/api/internal/repository"
	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// objects stores sealed audio and training items in the Garage bucket.
type objects struct {
	client *s3.Client
	bucket string
}

func newObjects(cfg config.Config) *objects {
	client := s3.New(s3.Options{
		BaseEndpoint:               aws.String(cfg.S3Endpoint),
		Region:                     cfg.S3Region,
		UsePathStyle:               true,
		Credentials:                aws.NewCredentialsCache(fileCredentials(cfg.S3CredentialsFile)),
		RequestChecksumCalculation: aws.RequestChecksumCalculationWhenRequired, // Garage rejects some default checksums
		ResponseChecksumValidation: aws.ResponseChecksumValidationWhenRequired,
	})
	return &objects{client: client, bucket: cfg.S3Bucket}
}

// fileCredentials re-reads rotating S3 keys and reports a short expiry so the cache refreshes them.
func fileCredentials(path string) aws.CredentialsProviderFunc {
	return func(context.Context) (aws.Credentials, error) {
		raw, err := os.ReadFile(path)
		if err != nil {
			return aws.Credentials{}, err
		}
		var creds struct {
			AccessKeyID     string `json:"access_key_id"`
			SecretAccessKey string `json:"secret_access_key"`
		}
		if err := json.Unmarshal(raw, &creds); err != nil {
			return aws.Credentials{}, fmt.Errorf("parse S3 credentials: %w", err)
		}
		return aws.Credentials{AccessKeyID: creds.AccessKeyID, SecretAccessKey: creds.SecretAccessKey, CanExpire: true, Expires: time.Now().Add(5 * time.Minute)}, nil
	}
}

func audioKey(sub, id string) string { return "glide/" + sub + "/audio/" + id }
func trainingKey(id string) string   { return "training/" + id }

func (o *objects) put(ctx context.Context, key string, body []byte, metadata map[string]string) error {
	_, err := o.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(o.bucket), Key: aws.String(key), Body: bytes.NewReader(body),
		ContentType: aws.String("application/octet-stream"), CacheControl: aws.String("private,no-store"), Metadata: metadata,
	})
	return err
}

func (o *objects) get(ctx context.Context, key string) (io.ReadCloser, int64, error) {
	out, err := o.client.GetObject(ctx, &s3.GetObjectInput{Bucket: aws.String(o.bucket), Key: aws.String(key)})
	var missing *types.NoSuchKey
	if errors.As(err, &missing) {
		return nil, 0, repository.ErrNotFound
	}
	if err != nil {
		return nil, 0, err
	}
	return out.Body, aws.ToInt64(out.ContentLength), nil
}

// delete succeeds when the object is already gone.
func (o *objects) delete(ctx context.Context, key string) error {
	_, err := o.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: aws.String(o.bucket), Key: aws.String(key)})
	return err
}

// deletePrefix removes every object under prefix, including any a failed delete left behind.
func (o *objects) deletePrefix(ctx context.Context, prefix string) error {
	pages := s3.NewListObjectsV2Paginator(o.client, &s3.ListObjectsV2Input{Bucket: aws.String(o.bucket), Prefix: aws.String(prefix)})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			return err
		}
		for _, object := range page.Contents {
			if err := o.delete(ctx, aws.ToString(object.Key)); err != nil {
				return err
			}
		}
	}
	return nil
}
