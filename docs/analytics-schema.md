# Analytical Database Schema Design

## Problem Statement

Current schema stores everything as generic JSON blobs:
- **interactions**: Generic message content (all in `content` TEXT column)
- **events**: Generic event data (all in `data` TEXT column)  
- **sessions**: Generic metadata (all in `metadata` TEXT column)

**Issue**: Requires JSON parsing for every query, no structured analytics, poor query performance.

## Solution: ETL + Star Schema for Analytics

### Architecture

```
Raw Data Layer (Current)          Analytics Layer (New)
├─ interactions (JSON blobs)  →   ├─ tool_executions
├─ events (JSON blobs)        →   ├─ errors
└─ sessions (JSON metadata)   →   ├─ performance_metrics
                                   ├─ client_sessions
                                   └─ session_lifecycle
```

### Phase 1: Core Analytics Tables

#### 1. tool_executions
**Purpose**: Structured tool call analytics

```sql
CREATE TABLE tool_executions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    request_id TEXT NOT NULL,
    
    -- Tool identification
    tool_name TEXT NOT NULL,
    tool_method TEXT,  -- MCP method (tools/call, etc.)
    
    -- Timing
    request_time DATETIME NOT NULL,
    response_time DATETIME,
    duration_ms REAL,
    
    -- I/O metrics
    input_size INTEGER,
    output_size INTEGER,
    argument_count INTEGER,
    
    -- Arguments (structured JSON for common patterns)
    arguments TEXT,  -- Still JSON but indexed separately
    
    -- Results
    status TEXT NOT NULL,  -- 'success', 'error', 'timeout'
    result_type TEXT,      -- 'text', 'error', 'streaming'
    result_summary TEXT,   -- First 500 chars for quick view
    
    -- Links to raw data
    interaction_request_id INTEGER,  -- FK to interactions.id
    interaction_response_id INTEGER, -- FK to interactions.id
    
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (interaction_request_id) REFERENCES interactions(id),
    FOREIGN KEY (interaction_response_id) REFERENCES interactions(id)
);

CREATE INDEX idx_tool_executions_session ON tool_executions(session_id, request_time DESC);
CREATE INDEX idx_tool_executions_tool ON tool_executions(tool_name, request_time DESC);
CREATE INDEX idx_tool_executions_status ON tool_executions(status, request_time DESC);
CREATE INDEX idx_tool_executions_duration ON tool_executions(duration_ms DESC);
CREATE INDEX idx_tool_executions_request ON tool_executions(request_id);
```

**Enables Queries Like:**
- Most used tools by session/client
- Average execution time per tool
- Success rate per tool
- Slowest tool executions
- Tool usage trends over time

#### 2. errors
**Purpose**: Structured error tracking and debugging

```sql
CREATE TABLE errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    
    -- Error classification
    error_type TEXT NOT NULL,  -- 'tool_error', 'protocol_error', 'system_error'
    error_code INTEGER,        -- JSON-RPC error codes (-32700, -32600, etc.)
    error_category TEXT,       -- 'parse_error', 'invalid_request', 'method_not_found', 'internal_error'
    
    -- Context
    tool_name TEXT,           -- If tool-related
    method TEXT,              -- MCP method that failed
    request_id TEXT,
    
    -- Error details
    message TEXT NOT NULL,
    stack_trace TEXT,
    
    -- Additional context
    client_info TEXT,         -- Client that triggered error
    input_that_caused_error TEXT,
    
    -- Resolution tracking
    resolved BOOLEAN DEFAULT 0,
    resolution_notes TEXT,
    
    -- Links
    interaction_id INTEGER,
    event_id INTEGER,
    
    FOREIGN KEY (session_id) REFERENCES sessions(session_id),
    FOREIGN KEY (interaction_id) REFERENCES interactions(id),
    FOREIGN KEY (event_id) REFERENCES events(id)
);

CREATE INDEX idx_errors_session ON errors(session_id, timestamp DESC);
CREATE INDEX idx_errors_type ON errors(error_type, timestamp DESC);
CREATE INDEX idx_errors_code ON errors(error_code, timestamp DESC);
CREATE INDEX idx_errors_tool ON errors(tool_name, timestamp DESC);
CREATE INDEX idx_errors_unresolved ON errors(resolved, timestamp DESC);
```

**Enables Queries Like:**
- Error rate per tool
- Most common error codes
- Error trends over time
- Unresolved errors requiring attention
- Debugging context for specific failures

#### 3. performance_metrics
**Purpose**: Time-series performance data for monitoring

```sql
CREATE TABLE performance_metrics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    
    -- Metric type
    metric_type TEXT NOT NULL,  -- 'tool_execution', 'request_routing', 'backend_communication'
    metric_name TEXT NOT NULL,  -- Specific metric
    
    -- Values
    duration_ms REAL,
    throughput REAL,           -- items/second
    memory_mb REAL,
    cpu_percent REAL,
    
    -- Dimensions
    tool_name TEXT,
    agent_id TEXT,
    
    -- Percentiles (for aggregated metrics)
    p50_ms REAL,
    p95_ms REAL,
    p99_ms REAL,
    
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

CREATE INDEX idx_metrics_session ON performance_metrics(session_id, timestamp DESC);
CREATE INDEX idx_metrics_type ON performance_metrics(metric_type, metric_name, timestamp DESC);
CREATE INDEX idx_metrics_tool ON performance_metrics(tool_name, timestamp DESC);
```

**Enables Queries Like:**
- Performance trends over time
- Identify performance degradation
- Compare tool performance
- Capacity planning data

#### 4. client_sessions
**Purpose**: Rich client metadata and capabilities

```sql
CREATE TABLE client_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    
    -- Client identification
    client_name TEXT NOT NULL,
    client_version TEXT,
    
    -- Connection details
    connect_time DATETIME NOT NULL,
    disconnect_time DATETIME,
    last_activity DATETIME,
    
    -- Client capabilities
    supports_streaming BOOLEAN,
    supports_notifications BOOLEAN,
    supported_content_types TEXT,  -- JSON array
    
    -- Protocol info
    protocol_version TEXT,
    initialization_params TEXT,    -- Full JSON for reference
    
    -- Routing
    target_repl TEXT,              -- Which REPL this session targets
    
    -- Activity summary
    total_requests INTEGER DEFAULT 0,
    total_errors INTEGER DEFAULT 0,
    total_data_sent INTEGER DEFAULT 0,
    total_data_received INTEGER DEFAULT 0,
    
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

CREATE INDEX idx_client_sessions_session ON client_sessions(session_id);
CREATE INDEX idx_client_sessions_client ON client_sessions(client_name, connect_time DESC);
CREATE INDEX idx_client_sessions_active ON client_sessions(disconnect_time) WHERE disconnect_time IS NULL;
```

**Enables Queries Like:**
- What clients are using the system
- Client version distribution
- Active vs. disconnected clients
- Client capability analysis
- Usage patterns by client type

#### 5. session_lifecycle
**Purpose**: Detailed session state changes

```sql
CREATE TABLE session_lifecycle (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    timestamp DATETIME NOT NULL,
    
    -- State transitions
    event_type TEXT NOT NULL,  -- 'created', 'initialized', 'connected', 'disconnected', 'reconnecting', 'terminated'
    from_state TEXT,
    to_state TEXT NOT NULL,
    
    -- Context
    reason TEXT,               -- Why the transition occurred
    triggered_by TEXT,         -- 'client', 'server', 'timeout', 'error'
    
    -- Additional data
    metadata TEXT,             -- JSON with event-specific data
    
    FOREIGN KEY (session_id) REFERENCES sessions(session_id)
);

CREATE INDEX idx_lifecycle_session ON session_lifecycle(session_id, timestamp);
CREATE INDEX idx_lifecycle_event ON session_lifecycle(event_type, timestamp DESC);
CREATE INDEX idx_lifecycle_state ON session_lifecycle(to_state, timestamp DESC);
```

**Enables Queries Like:**
- Session state machine analysis
- Common failure patterns
- Session duration calculations
- Reconnection patterns

### Phase 2: Aggregated Views

#### Daily Tool Usage Summary
```sql
CREATE VIEW v_daily_tool_usage AS
SELECT 
    DATE(request_time) as date,
    tool_name,
    COUNT(*) as execution_count,
    AVG(duration_ms) as avg_duration_ms,
    MIN(duration_ms) as min_duration_ms,
    MAX(duration_ms) as max_duration_ms,
    SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) as error_count,
    ROUND(100.0 * SUM(CASE WHEN status = 'error' THEN 1 ELSE 0 END) / COUNT(*), 2) as error_rate_pct
FROM tool_executions
GROUP BY DATE(request_time), tool_name
ORDER BY date DESC, execution_count DESC;
```

#### Session Summary
```sql
CREATE VIEW v_session_summary AS
SELECT 
    s.session_id,
    s.start_time,
    s.last_activity,
    s.status,
    cs.client_name,
    cs.client_version,
    COUNT(DISTINCT te.id) as total_tool_calls,
    COUNT(DISTINCT e.id) as total_errors,
    SUM(te.duration_ms) as total_execution_time_ms,
    AVG(te.duration_ms) as avg_execution_time_ms
FROM sessions s
LEFT JOIN client_sessions cs ON s.session_id = cs.session_id
LEFT JOIN tool_executions te ON s.session_id = te.session_id
LEFT JOIN errors e ON s.session_id = e.session_id
GROUP BY s.session_id;
```

#### Error Hot Spots
```sql
CREATE VIEW v_error_hotspots AS
SELECT 
    tool_name,
    error_type,
    error_category,
    COUNT(*) as error_count,
    COUNT(DISTINCT session_id) as affected_sessions,
    MAX(timestamp) as last_occurrence
FROM errors
WHERE resolved = 0
GROUP BY tool_name, error_type, error_category
ORDER BY error_count DESC;
```

### Phase 3: ETL Process Design

#### ETL Function Architecture

```julia
module DatabaseETL

using SQLite
using JSON
using Dates
using DataFrames

# Main ETL coordinator
function run_etl_pipeline(db; mode = :incremental)
    if mode == :full
        @info "Running FULL ETL refresh"
        truncate_analytics_tables(db)
        last_processed_id = 0
    else
        @info "Running INCREMENTAL ETL"
        last_processed_id = get_last_processed_id(db)
    end
    
    # Extract and transform interactions into tool_executions
    extract_tool_executions(db, last_processed_id)
    
    # Extract errors from interactions and events
    extract_errors(db, last_processed_id)
    
    # Calculate performance metrics
    calculate_performance_metrics(db)
    
    # Update client session summaries
    update_client_sessions(db)
    
    # Update session lifecycle
    update_session_lifecycle(db)
    
    # Update last processed marker
    update_etl_metadata(db)
    
    @info "ETL pipeline complete"
end

# Extract tool executions from interactions
function extract_tool_executions(db, last_id)
    # Query for new request/response pairs
    query = """
        SELECT 
            req.id as req_id,
            resp.id as resp_id,
            req.session_id,
            req.request_id,
            req.timestamp as request_time,
            resp.timestamp as response_time,
            req.method,
            req.content as request_content,
            resp.content as response_content
        FROM interactions req
        LEFT JOIN interactions resp 
            ON req.request_id = resp.request_id 
            AND resp.direction = 'outbound'
        WHERE req.direction = 'inbound'
            AND req.message_type = 'request'
            AND req.method = 'tools/call'
            AND req.id > ?
        ORDER BY req.id
    """
    
    df = DBInterface.execute(db, query, (last_id,)) |> DataFrame
    
    for row in eachrow(df)
        # Parse request content
        req_data = JSON.parse(row.request_content)
        params = get(req_data, "params", Dict())
        tool_name = get(params, "name", "unknown")
        arguments = get(params, "arguments", Dict())
        
        # Parse response content (if available)
        status = "pending"
        result_type = nothing
        result_summary = nothing
        response_time = row.response_time
        
        if !ismissing(row.response_content)
            resp_data = JSON.parse(row.response_content)
            
            if haskey(resp_data, "result")
                status = "success"
                result = resp_data["result"]
                result_type = haskey(result, "content") ? "text" : "other"
                
                if result_type == "text" && !isempty(result["content"])
                    content_text = result["content"][1]["text"]
                    result_summary = first(content_text, 500)
                end
            elseif haskey(resp_data, "error")
                status = "error"
                result_type = "error"
                result_summary = resp_data["error"]["message"]
            end
        end
        
        # Calculate metrics
        duration_ms = if !ismissing(response_time)
            (DateTime(response_time) - DateTime(row.request_time)).value
        else
            nothing
        end
        
        input_size = sizeof(row.request_content)
        output_size = ismissing(row.response_content) ? 0 : sizeof(row.response_content)
        argument_count = length(arguments)
        
        # Insert into tool_executions
        DBInterface.execute(db, """
            INSERT INTO tool_executions (
                session_id, request_id, tool_name, tool_method,
                request_time, response_time, duration_ms,
                input_size, output_size, argument_count,
                arguments, status, result_type, result_summary,
                interaction_request_id, interaction_response_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            row.session_id, row.request_id, tool_name, row.method,
            row.request_time, response_time, duration_ms,
            input_size, output_size, argument_count,
            JSON.json(arguments), status, result_type, result_summary,
            row.req_id, ismissing(row.resp_id) ? nothing : row.resp_id
        ))
    end
    
    @info "Extracted $(nrow(df)) tool executions"
end

# Extract errors
function extract_errors(db, last_id)
    # Extract from interactions with error responses
    query = """
        SELECT 
            i.id,
            i.session_id,
            i.timestamp,
            i.request_id,
            i.method,
            i.content
        FROM interactions i
        WHERE i.direction = 'outbound'
            AND i.message_type = 'response'
            AND JSON_EXTRACT(i.content, '$.error') IS NOT NULL
            AND i.id > ?
    """
    
    df = DBInterface.execute(db, query, (last_id,)) |> DataFrame
    
    for row in eachrow(df)
        content = JSON.parse(row.content)
        error_obj = content["error"]
        
        error_code = get(error_obj, "code", nothing)
        error_message = get(error_obj, "message", "Unknown error")
        
        # Categorize error
        error_category = categorize_error_code(error_code)
        error_type = startswith(row.method, "tools/") ? "tool_error" : "protocol_error"
        
        # Try to find the tool name from request
        tool_name = find_tool_name_for_request(db, row.request_id)
        
        DBInterface.execute(db, """
            INSERT INTO errors (
                session_id, timestamp, error_type, error_code, error_category,
                tool_name, method, request_id, message, interaction_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            row.session_id, row.timestamp, error_type, error_code, error_category,
            tool_name, row.method, row.request_id, error_message, row.id
        ))
    end
    
    @info "Extracted $(nrow(df)) errors"
end

# Helper functions
function categorize_error_code(code)
    code_map = Dict(
        -32700 => "parse_error",
        -32600 => "invalid_request",
        -32601 => "method_not_found",
        -32602 => "invalid_params",
        -32603 => "internal_error"
    )
    get(code_map, code, "unknown_error")
end

function find_tool_name_for_request(db, request_id)
    result = DBInterface.execute(db, """
        SELECT JSON_EXTRACT(content, '$.params.name') as tool_name
        FROM interactions
        WHERE request_id = ? AND direction = 'inbound'
        LIMIT 1
    """, (request_id,))
    
    for row in result
        return row.tool_name
    end
    return nothing
end

# Performance metrics calculation
function calculate_performance_metrics(db)
    # Calculate hourly aggregates for recent data
    # This could run periodically to create summary metrics
    @info "Calculating performance metrics"
    
    # Example: Calculate p50, p95, p99 for each tool in last hour
    # ... implementation
end

# Schedule ETL to run periodically
function start_etl_scheduler(db; interval_seconds = 60)
    @info "Starting ETL scheduler (every $(interval_seconds)s)"
    
    @async while true
        try
            run_etl_pipeline(db; mode = :incremental)
        catch e
            @error "ETL pipeline failed" exception=e
        end
        sleep(interval_seconds)
    end
end

end # module DatabaseETL
```

### Implementation Plan

**Priority 1: Core Tables** (Immediate Value)
1. Create `tool_executions` table
2. Create `errors` table  
3. Implement basic ETL for these two tables
4. Add to dashboard UI

**Priority 2: Performance Monitoring**
5. Create `performance_metrics` table
6. Add real-time metric calculation
7. Create performance dashboard view

**Priority 3: Advanced Analytics**
8. Create `client_sessions` table
9. Create `session_lifecycle` table
10. Add aggregated views
11. Add trend analysis and alerting

### Dashboard Integration

New dashboard tabs/views:
- **Tool Analytics**: Most used tools, average execution times, success rates
- **Error Dashboard**: Recent errors, error trends, unresolved issues
- **Performance Monitor**: Real-time metrics, percentile charts
- **Client Activity**: Active clients, usage patterns
- **Session Timeline**: Enhanced with structured lifecycle events

### Benefits

1. **Query Performance**: No JSON parsing for analytics queries
2. **Structured Analysis**: Direct SQL queries on typed columns
3. **Time-Series Analysis**: Proper temporal queries with indices
4. **Alerting Ready**: Can set up triggers on error rates, performance degradation
5. **Data Warehouse Ready**: Clean schema for BI tools (Grafana, Metabase, etc.)
6. **ML Ready**: Structured data for anomaly detection, usage prediction

### Migration Strategy

1. **Parallel Operation**: Keep raw data in interactions/events
2. **Gradual ETL**: Process historical data in batches
3. **Fallback**: Can always rebuild analytics from raw data
4. **Validation**: Compare analytics results with raw data queries
5. **Zero Downtime**: ETL runs async, doesn't block proxy

This transforms Kaimon from just logging to a full **observability platform**! 🚀
