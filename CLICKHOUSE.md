# ClickHouse — Querying OpenLIT's Data

OpenLIT stores its traces, metrics and logs in ClickHouse (`openlit-db`, 24.4.1, in the `openlit`
namespace), in the `openlit` database. The UI stores users, settings and API keys in SQLite on a
5Gi PVC. ClickHouse can't be reached from outside the
namespace, so open it with a port-forward or a `kubectl exec`. Backups and restores are covered
in [README.md](README.md#openlit).

> These credentials are ClickHouse's `default` admin user: they can change and drop OpenLIT's
> data. Stick to `SELECT` unless you mean it.

## Connecting

**Browser (Play UI):**

```bash
kubectl -n openlit port-forward svc/openlit-db 8123:8123
# open http://localhost:8123/play - user `default`, password from:
kubectl -n openlit get secret openlit-clickhouse -o jsonpath='{.data.password}' | base64 -d; echo
```

**Terminal:** inside the pod, the password is already in the environment:

```bash
kubectl -n openlit exec -it openlit-db-0 -- \
  bash -c 'clickhouse-client --user "$CLICKHOUSE_USER" --password "$CLICKHOUSE_PASSWORD" -d openlit'
```

The password is generated in the cluster (External Secrets `Password` generator), so a new
cluster gets a new one.

## Exploring

```sql
-- Tables, row counts and sizes
SELECT name, total_rows, formatReadableSize(total_bytes) AS size
FROM system.tables
WHERE database = 'openlit'
ORDER BY total_rows DESC;

-- Columns of the traces table
DESCRIBE openlit.otel_traces;

-- Rows OpenLIT ships with (model metadata), so there's data before any telemetry arrives
SELECT * FROM openlit.openlit_provider_models LIMIT 10;

-- Attribute keys your spans actually carry
SELECT DISTINCT arrayJoin(mapKeys(SpanAttributes)) AS key
FROM openlit.otel_traces
ORDER BY key;
```

## Traces

`openlit.otel_traces` has the OpenTelemetry ClickHouse exporter's schema: `Timestamp`, `TraceId`,
`SpanId`, `ParentSpanId`, `ServiceName`, `SpanName`, `SpanKind`, `Duration` (nanoseconds),
`StatusCode`, `StatusMessage`, and the `SpanAttributes` / `ResourceAttributes` maps. The `gen_ai.*`
attributes follow the OpenTelemetry GenAI semantic conventions that OpenLIT's SDK emits.

```sql
-- LLM calls per model in the last 24h: count, average latency, tokens, cost
SELECT
  SpanAttributes['gen_ai.request.model']                             AS model,
  count()                                                            AS calls,
  round(avg(Duration) / 1e6)                                         AS avg_ms,
  sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.input_tokens']))   AS input_tokens,
  sum(toUInt64OrZero(SpanAttributes['gen_ai.usage.output_tokens']))  AS output_tokens,
  round(sum(toFloat64OrZero(SpanAttributes['gen_ai.usage.cost'])), 4) AS cost_usd
FROM openlit.otel_traces
WHERE Timestamp > now() - INTERVAL 1 DAY
  AND SpanAttributes['gen_ai.request.model'] != ''
GROUP BY model
ORDER BY calls DESC;

-- Latency percentiles per service and operation (last hour)
SELECT
  ServiceName,
  SpanName,
  count()                                       AS spans,
  round(quantile(0.5)(Duration) / 1e6, 1)       AS p50_ms,
  round(quantile(0.95)(Duration) / 1e6, 1)      AS p95_ms
FROM openlit.otel_traces
WHERE Timestamp > now() - INTERVAL 1 HOUR
GROUP BY ServiceName, SpanName
ORDER BY spans DESC
LIMIT 20;

-- The 20 most recent failed spans
SELECT Timestamp, ServiceName, SpanName, StatusMessage
FROM openlit.otel_traces
WHERE StatusCode = 'Error'
ORDER BY Timestamp DESC
LIMIT 20;

-- Every span of one trace, in order
SELECT Timestamp, SpanName, ParentSpanId, round(Duration / 1e6, 1) AS ms
FROM openlit.otel_traces
WHERE TraceId = '<trace-id>'
ORDER BY Timestamp;

-- Spans per minute (last hour), to check telemetry is flowing
SELECT toStartOfMinute(Timestamp) AS minute, count() AS spans
FROM openlit.otel_traces
WHERE Timestamp > now() - INTERVAL 1 HOUR
GROUP BY minute
ORDER BY minute;
```

## Storage

```sql
-- Disk used per table, compressed vs. uncompressed
SELECT
  table,
  formatReadableSize(sum(data_compressed_bytes))   AS compressed,
  formatReadableSize(sum(data_uncompressed_bytes)) AS uncompressed,
  sum(rows)                                        AS rows
FROM system.parts
WHERE database = 'openlit' AND active
GROUP BY table
ORDER BY sum(data_compressed_bytes) DESC;
```

The ClickHouse PVC is 10Gi; `kubectl -n openlit exec openlit-db-0 -- df -h /var/lib/clickhouse`
shows how full it is.
