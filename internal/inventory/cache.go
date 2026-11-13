// Package inventory builds the read-only views (databases, snapshots,
// backup plans, schedules, activity) from live AWS data reached only
// through the guarded clients in internal/awsx. Nothing in this package
// ever calls a mutating AWS operation.
package inventory

import (
	"context"
	"sort"
	"strings"
	"sync"
	"time"

	"golang.org/x/sync/errgroup"
)

// cacheTTL is how long a listing stays fresh before a caller must refresh
// it explicitly; it keeps the UI responsive without hammering AWS on every
// view switch.
const cacheTTL = 60 * time.Second

type cacheEntry struct {
	value   any
	expires time.Time
}

// ttlCache is a small per-process cache keyed by an arbitrary string built
// from account, region and listing kind. It holds only mapped read-model
// values, never credentials, and never survives a process restart.
type ttlCache struct {
	mu      sync.Mutex
	entries map[string]cacheEntry
}

func newTTLCache() *ttlCache {
	return &ttlCache{entries: map[string]cacheEntry{}}
}

func (c *ttlCache) get(key string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[key]
	if !ok || time.Now().After(e.expires) {
		return nil, false
	}
	return e.value, true
}

func (c *ttlCache) set(key string, value any) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.entries[key] = cacheEntry{value: value, expires: time.Now().Add(cacheTTL)}
}

// invalidate drops every cached entry whose key starts with prefix, so a
// write action (a new snapshot, a modified retention window) can force the
// next read for just the affected account to bypass the cache.
func (c *ttlCache) invalidate(prefix string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for k := range c.entries {
		if strings.HasPrefix(k, prefix) {
			delete(c.entries, k)
		}
	}
}

// defaultCache backs every lister in this package.
var defaultCache = newTTLCache()

// cached returns the cached value for key if still fresh, otherwise calls
// fn, caches a successful result, and returns it. An error from fn is never
// cached, so the next call retries.
func cached[T any](cache *ttlCache, key string, fn func() (T, error)) (T, error) {
	if v, ok := cache.get(key); ok {
		return v.(T), nil
	}
	val, err := fn()
	if err != nil {
		var zero T
		return zero, err
	}
	cache.set(key, val)
	return val, nil
}

// fanOutRegions runs fn for each region concurrently, limited to 8 at a
// time. A failing region never aborts the others; its error is reported in
// the returned map keyed by region, so a bad region becomes a per-account
// error banner rather than a whole-page failure.
func fanOutRegions(ctx context.Context, regions []string, fn func(ctx context.Context, region string) error) map[string]error {
	errs := make(map[string]error, len(regions))
	var mu sync.Mutex

	var g errgroup.Group
	g.SetLimit(8)
	for _, region := range regions {
		region := region
		g.Go(func() error {
			if err := fn(ctx, region); err != nil {
				mu.Lock()
				errs[region] = err
				mu.Unlock()
			}
			return nil
		})
	}
	_ = g.Wait()
	return errs
}

// joinErrs renders a region/account error map as one deterministic message.
func joinErrs(errs map[string]error) string {
	parts := make([]string, 0, len(errs))
	for region, err := range errs {
		parts = append(parts, region+": "+err.Error())
	}
	sort.Strings(parts)
	return strings.Join(parts, "; ")
}
