package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

type nativeSourceTask struct {
	cancel context.CancelFunc
}

type nativeSourceRecord struct {
	Operation       string               `json:"operation"`
	Running         bool                 `json:"running"`
	Stage           string               `json:"stage"`
	Completed       int                  `json:"completed"`
	Total           int                  `json:"total"`
	Added           int                  `json:"added"`
	Error           string               `json:"error,omitempty"`
	StartedAt       time.Time            `json:"startedAt"`
	FinishedAt      time.Time            `json:"finishedAt"`
	RetryAt         time.Time            `json:"retryAt"`
	Health          *nativeSourceHealth  `json:"health,omitempty"`
	MetadataChecked map[string]time.Time `json:"metadataChecked,omitempty"`
}

type nativeSourceStatus struct {
	Source     string              `json:"source"`
	Count      int                 `json:"count"`
	Page       int                 `json:"page"`
	HasMore    bool                `json:"hasMore"`
	UpdatedAt  time.Time           `json:"updatedAt"`
	Operation  string              `json:"operation"`
	Running    bool                `json:"running"`
	Stage      string              `json:"stage"`
	Completed  int                 `json:"completed"`
	Total      int                 `json:"total"`
	Added      int                 `json:"added"`
	Error      string              `json:"error,omitempty"`
	StartedAt  time.Time           `json:"startedAt"`
	FinishedAt time.Time           `json:"finishedAt"`
	RetryAt    time.Time           `json:"retryAt"`
	Health     *nativeSourceHealth `json:"health,omitempty"`
}

func (engine *nativeEngine) lockSourceCatalog(ctx context.Context, source string) (func(), error) {
	engine.sourceCatalogMu.Lock()
	if engine.sourceCatalogs == nil {
		engine.sourceCatalogs = map[string]chan struct{}{}
	}
	gate := engine.sourceCatalogs[source]
	if gate == nil {
		gate = make(chan struct{}, 1)
		engine.sourceCatalogs[source] = gate
	}
	engine.sourceCatalogMu.Unlock()
	select {
	case gate <- struct{}{}:
		return func() { <-gate }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (engine *nativeEngine) loadSourceRecords() {
	engine.sourceRecords = map[string]nativeSourceRecord{}
	engine.sourceTasks = map[string]*nativeSourceTask{}
	path := filepath.Join(engine.directory, "sources.json")
	info, err := os.Stat(path)
	if err != nil || info.Size() > 4<<20 {
		return
	}
	body, err := os.ReadFile(path)
	var records map[string]nativeSourceRecord
	if err != nil || json.Unmarshal(body, &records) != nil {
		return
	}
	for source, record := range records {
		if !isHuangguoProviderSource(source) {
			continue
		}
		if record.Running {
			record.Running = false
			record.Stage = "任务已中断"
			record.Error = "上次任务未完成，已保留已更新内容，可重新开始"
		}
		engine.sourceRecords[source] = record
	}
}

func (engine *nativeEngine) saveSourceRecordsLocked() {
	body, err := json.Marshal(engine.sourceRecords)
	if err == nil && len(body) <= 4<<20 {
		_ = writeNativeCacheFile(filepath.Join(engine.directory, "sources.json"), body)
	}
}

func (engine *nativeEngine) sourceStatus(source string) nativeSourceStatus {
	source = canonicalProviderSource(source)
	engine.mu.Lock()
	defer engine.mu.Unlock()
	return engine.sourceStatusLocked(source)
}

func (engine *nativeEngine) sourceStatusLocked(source string) nativeSourceStatus {
	record := engine.sourceRecords[source]
	state, found := engine.catalogStates[source]
	return nativeSourceStatus{Source: source, Count: len(engine.catalogs[source]), Page: max(1, state.Page), HasMore: !found || state.HasMore,
		UpdatedAt: state.UpdatedAt, Operation: record.Operation, Running: record.Running, Stage: record.Stage,
		Completed: record.Completed, Total: record.Total, Added: record.Added, Error: record.Error,
		StartedAt: record.StartedAt, FinishedAt: record.FinishedAt, RetryAt: record.RetryAt, Health: record.Health}
}

func (engine *nativeEngine) changeSourceRecord(source string, change func(*nativeSourceRecord)) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.sourceRecords == nil {
		engine.sourceRecords = map[string]nativeSourceRecord{}
	}
	record := engine.sourceRecords[source]
	change(&record)
	engine.sourceRecords[source] = record
	engine.saveSourceRecordsLocked()
}

func (engine *nativeEngine) startSourceTask(source, operation string, drama nativeDrama) (nativeSourceStatus, error) {
	source = canonicalProviderSource(source)
	if !nativeSourceAvailable(source) {
		return nativeSourceStatus{}, errNativeBuildSource
	}
	switch operation {
	case "update", "more", "metadata", "check", "checkCatalog":
	default:
		return nativeSourceStatus{}, errors.New("无效的站源操作")
	}
	if drama.ID != "" && (!nativeDramaAvailable(drama) || sourceFromDramaID(drama.ID) != source) {
		return nativeSourceStatus{}, errNativeBuildSource
	}
	engine.mu.Lock()
	if engine.sourceTasks == nil {
		engine.sourceTasks = map[string]*nativeSourceTask{}
	}
	if task := engine.sourceTasks[source]; task != nil {
		status := engine.sourceStatusLocked(source)
		engine.mu.Unlock()
		return status, nil
	}
	if engine.sourceRecords == nil {
		engine.sourceRecords = map[string]nativeSourceRecord{}
	}
	previous := engine.sourceRecords[source]
	if time.Now().Before(previous.RetryAt) {
		engine.mu.Unlock()
		return nativeSourceStatus{}, fmt.Errorf("站源暂时暂停请求，请在 %d 秒后重试", max(1, int(time.Until(previous.RetryAt).Seconds()+.999)))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	task := &nativeSourceTask{cancel: cancel}
	engine.sourceTasks[source] = task
	previous.Operation, previous.Running, previous.Stage = operation, true, "准备中"
	previous.Completed, previous.Total, previous.Added = 0, 0, 0
	previous.Error, previous.StartedAt, previous.FinishedAt, previous.RetryAt = "", time.Now(), time.Time{}, time.Time{}
	engine.sourceRecords[source] = previous
	engine.saveSourceRecordsLocked()
	status := engine.sourceStatusLocked(source)
	engine.mu.Unlock()
	go engine.runSourceTask(ctx, source, operation, drama, task)
	return status, nil
}

func (engine *nativeEngine) cancelSourceTask(source string) nativeSourceStatus {
	source = canonicalProviderSource(source)
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if task := engine.sourceTasks[source]; task != nil {
		task.cancel()
		record := engine.sourceRecords[source]
		record.Stage = "正在停止"
		engine.sourceRecords[source] = record
	}
	return engine.sourceStatusLocked(source)
}

func (engine *nativeEngine) runSourceTask(ctx context.Context, source, operation string, drama nativeDrama, task *nativeSourceTask) {
	var err error
	defer func() {
		if recover() != nil {
			err = errors.New("站源任务处理失败，已保留缓存")
		}
		task.cancel()
		engine.mu.Lock()
		defer engine.mu.Unlock()
		delete(engine.sourceTasks, source)
		record := engine.sourceRecords[source]
		record.Running, record.FinishedAt = false, time.Now()
		record.Stage = "已完成"
		if err != nil {
			record.Stage, record.Error = "未完成", publicError(err).Error()
			if errors.Is(err, context.Canceled) {
				record.Stage, record.Error = "已停止", "已保留更新内容，可稍后继续"
			}
			if errors.Is(err, context.DeadlineExceeded) {
				record.Error = "本次站源任务超时，已保留更新内容，可继续更新"
			}
			var backoff *requestBackoff
			if errors.As(err, &backoff) {
				record.RetryAt = backoff.until
			}
		}
		engine.sourceRecords[source] = record
		engine.saveSourceRecordsLocked()
	}()
	if operation == "check" || operation == "checkCatalog" {
		err = engine.checkSource(ctx, source, drama, operation == "check")
	} else {
		ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
		err = engine.updateSource(ctx, source, operation)
	}
}

func (engine *nativeEngine) updateSource(ctx context.Context, source, operation string) error {
	before := engine.nativeCached(source)
	count := len(before.Items)
	defer func() {
		after := len(engine.nativeCached(source).Items)
		engine.changeSourceRecord(source, func(record *nativeSourceRecord) { record.Added = max(0, after-count) })
	}()
	if operation == "update" {
		engine.changeSourceRecord(source, func(record *nativeSourceRecord) { record.Stage = "查找新剧" })
		page, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Page: 1, Force: true})
		if err != nil {
			return err
		}
		if page.Warning != "" {
			return errors.New(page.Warning)
		}
	}
	if operation == "more" || operation == "update" && before.HasMore && len(before.Items) > 0 {
		engine.changeSourceRecord(source, func(record *nativeSourceRecord) { record.Stage = "继续加载历史分页" })
		current := engine.nativeCached(source)
		if current.HasMore {
			next := current.Page + 1
			if len(current.Items) == 0 {
				next = 1
			}
			page, err := engine.nativeCatalog(ctx, nativeInput{Source: source, Page: next, Force: true})
			if err != nil {
				return err
			}
			if page.Warning != "" {
				return errors.New(page.Warning)
			}
		}
	}
	if operation == "more" {
		return nil
	}
	items := engine.nativeCached(source).Items
	var pending []nativeDrama
	engine.mu.Lock()
	record := engine.sourceRecords[source]
	for _, drama := range items {
		if len(pending) >= 8 {
			break
		}
		if time.Since(record.MetadataChecked[drama.ID]) < 24*time.Hour {
			continue
		}
		if operation == "metadata" || drama.Episodes <= 0 || drama.Description == "" {
			pending = append(pending, drama)
		}
	}
	engine.mu.Unlock()
	engine.changeSourceRecord(source, func(record *nativeSourceRecord) {
		record.Stage, record.Completed, record.Total = "补齐剧集资料", 0, len(pending)
	})
	var failures []error
	for index, drama := range pending {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		result, err := engine.nativeDetail(ctx, drama)
		if err == nil {
			fresh := result.(map[string]any)["drama"].(nativeDrama)
			engine.mu.Lock()
			engine.catalogs[source] = mergeNativeCatalog(engine.catalogs[source], []nativeDrama{fresh})
			body, marshalErr := json.Marshal(nativeCatalogDisk{Version: 2, Catalogs: engine.catalogs, States: engine.catalogStates})
			if marshalErr == nil {
				err = writeNativeCacheFile(filepath.Join(engine.directory, "catalogs.json"), body)
			}
			engine.mu.Unlock()
		}
		engine.changeSourceRecord(source, func(record *nativeSourceRecord) {
			record.Completed = index + 1
			if err == nil {
				if record.MetadataChecked == nil {
					record.MetadataChecked = map[string]time.Time{}
				}
				record.MetadataChecked[drama.ID] = time.Now()
			}
		})
		if err != nil {
			failures = append(failures, err)
			var backoff *requestBackoff
			if errors.As(err, &backoff) || len(failures) >= 2 {
				break
			}
		}
	}
	return errors.Join(failures...)
}
