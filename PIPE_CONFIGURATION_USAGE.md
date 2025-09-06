# PipeConfiguration with Stage Arrays

This document demonstrates the usage of `PipeConfiguration` with stage arrays and the visually appealing `|>` operator for final I/O specification.

## Key Features

- **Type-safe pipeline construction** with generic parameters
- **Clean stage array API** - I/O configuration specified at the end with `.finally()` or `|>`  
- **Shell-like operators** - `|` for intermediate processes, `|>` for final I/O specification
- **Concurrent execution** - automatic process parallelization with `withThrowingTaskGroup`
- **Flexible error redirection** - control how stderr is handled in pipelines

## API Design Philosophy

The `PipeConfiguration` API uses a **stage array pattern**: 

1. **pipe() functions return stage arrays** - when you call `pipe()`, it returns `[PipeStage]`
2. **Pipe operators build stage arrays** - intermediate stages build up arrays of `PipeStage`  
3. **finally() or |> specify I/O** - only at the end do you specify the real input/output/error types

This eliminates interim `PipeConfiguration` objects with discarded I/O and makes pipeline construction clean and direct.

## Basic Usage

### Single Process
```swift
// Using .finally() method
let config = pipe(
    executable: .name("echo"),
    arguments: ["Hello World"]
).finally(
    output: .string(limit: .max)
)

// Using |> operator (visually appealing!)
let config = pipe(
    executable: .name("echo"),
    arguments: ["Hello World"]
) |> .string(limit: .max)

let result = try await config.run()
print(result.standardOutput) // "Hello World"
```

### Pipeline with Stage Arrays

**✅ Using .finally() method:**
```swift
let pipeline = (pipe(
    executable: .name("echo"),
    arguments: ["apple\nbanana\ncherry"]
) | .name("sort")                     // ✅ Builds stage array
  | .name("head")                     // ✅ Continues building array
  | process(                          // ✅ Adds configured stage
    executable: .name("wc"),
    arguments: ["-l"]
  )).finally(
    output: .string(limit: .max),     // ✅ Only here we specify real I/O
    error: .discarded
)
```

**✅ Using |> operator (clean and visually appealing!):**
```swift
let pipeline = pipe(
    executable: .name("echo"),
    arguments: ["apple\nbanana\ncherry"]
) | .name("sort")                     // ✅ Builds stage array
  | .name("head")                     // ✅ Continues building array  
  | process(                          // ✅ Adds configured stage
    executable: .name("wc"),
    arguments: ["-l"]
  ) |> (                              // ✅ Visually appealing final I/O!
    output: .string(limit: .max),
    error: .discarded
  )

let result = try await pipeline.run()
print(result.standardOutput) // "3"
```

## Error Redirection

PipeConfiguration now supports three modes for handling standard error:

### `.separate` (Default)
```swift
let config = pipe(
    executable: .name("sh"),
    arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
    options: .default  // or ProcessStageOptions(errorRedirection: .separate)
) |> (
    output: .string(limit: .max),
    error: .string(limit: .max)
)

let result = try await config.run()
// result.standardOutput contains "stdout"
// result.standardError contains "stderr"
```

### `.replaceStdout` - Redirect stderr to stdout, discard original stdout
```swift
let config = pipe(
    executable: .name("sh"),
    arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
    options: .stderrToStdout  // Convenience for .replaceStdout
) |> (
    output: .string(limit: .max),
    error: .string(limit: .max)
)

let result = try await config.run()
// result.standardOutput contains "stderr" (stdout was discarded)
// result.standardError contains "stderr"
```

### `.mergeWithStdout` - Both stdout and stderr go to the same destination
```swift
let config = pipe(
    executable: .name("sh"),
    arguments: ["-c", "echo 'stdout'; echo 'stderr' >&2"],
    options: .mergeErrors  // Convenience for .mergeWithStdout
) |> (
    output: .string(limit: .max),  
    error: .string(limit: .max)
)

let result = try await config.run()
// Both result.standardOutput and result.standardError contain both "stdout" and "stderr"
```

## Error Redirection in Pipelines

### Using `withOptions()` helper
```swift
let pipeline = finally(
    stages: pipe(
        executable: .name("sh"),
        arguments: ["-c", "echo 'data'; echo 'warning' >&2"],
        options: .mergeErrors  // Merge stderr into stdout
    ) | withOptions(
        configuration: Configuration(executable: .name("grep"), arguments: ["warning"]),
        options: .default
    ) | process(
        executable: .name("wc"),
        arguments: ["-l"]
    ),
    output: .string(limit: .max),
    error: .discarded
)

let result = try await pipeline.run()
// Should find the warning that was merged into stdout
```

### Using `process()` helper with options
```swift
let pipeline = finally(
    stages: pipe(
        executable: .name("find"),
        arguments: ["/some/path"]
    ) | process(
        executable: .name("grep"),
        arguments: ["-v", "Permission denied"],
        options: .stderrToStdout  // Convert any stderr to stdout
    ) | process(
        executable: .name("wc"),
        arguments: ["-l"]
    ),
    output: .string(limit: .max),
    error: .discarded
)
```

## Operator Variants

### Stage Array Operators (`|`)
```swift
stages | process(.name("grep"))                   // Add simple process stage
stages | Configuration(executable: ...)           // Add configuration stage  
stages | process(                                 // Add with arguments and options
    executable: .name("sort"),
    arguments: ["-r"],
    options: .mergeErrors
)
stages | withOptions(                             // Configuration with options
    configuration: myConfig,
    options: .stderrToStdout
)
stages | { input, output, error in               // Add Swift function stage
    // Swift function implementation
    return 0
}
```

### Final Operators (`|>`)
```swift
stages |> (output: .string(limit: .max), error: .discarded)  // Simple final output
stages |> .string(limit: .max)                               // Output only (discarded error)
```

## Helper Functions

### `finally()` - For creating PipeConfiguration from stage arrays
```swift
finally(stages: myStages, output: .string(limit: .max), error: .discarded)
finally(stages: myStages, output: .string(limit: .max))  // Auto-discard error
finally(stages: myStages, input: .string("data"), output: .string(limit: .max), error: .discarded)
```

### `process()` - For creating individual process stages
```swift
process(executable: .name("grep"), arguments: ["pattern"])
process(executable: .name("sort"), arguments: ["-r"], environment: .inherit)
process(executable: .name("cat"), options: .mergeErrors)
process(
    executable: .name("awk"),
    arguments: ["{print $1}"],
    options: .stderrToStdout
)
```

### `withOptions()` - For creating Configuration stages with options
```swift
withOptions(configuration: myConfig, options: .mergeErrors)
withOptions(configuration: myConfig, options: .stderrToStdout)
```

## Real-World Examples

### Log Processing with Error Handling
```swift
let logProcessor = pipe(
    executable: .name("tail"),
    arguments: ["-f", "/var/log/app.log"],
    options: .mergeErrors  // Capture any tail errors as data
) | process(
    executable: .name("grep"),
    arguments: ["-E", "(ERROR|WARN)"],
    options: .stderrToStdout  // Convert grep errors to output
) |> finally(
    executable: .name("head"),
    arguments: ["-20"],
    output: .string(limit: .max),
    error: .string(limit: .max)  // Capture final errors separately
)
```

### File Processing with Error Recovery
```swift
let fileProcessor = pipe(
    executable: .name("find"),
    arguments: ["/data", "-name", "*.log", "-type", "f"],
    options: .replaceStdout  // Convert permission errors to "output"
) | process(
    executable: .name("head"),
    arguments: ["-100"],  // Process first 100 files/errors
    options: .mergeErrors
) |> finally(
    executable: .name("wc"),
    arguments: ["-l"],
    output: .string(limit: .max),
    error: .discarded
)
```

## Swift Functions with JSON Processing

PipeConfiguration supports embedding Swift functions directly in pipelines, which is particularly powerful for JSON processing tasks where you need Swift's type safety and `Codable` support.

### JSON Transformation Pipeline
```swift
struct InputData: Codable {
    let items: [String]
    let metadata: [String: String]
}

struct OutputData: Codable {
    let processedItems: [String]
    let itemCount: Int
    let processingDate: String
}

let pipeline = pipe(
    executable: .name("echo"),
    arguments: [#"{"items": ["apple", "banana", "cherry"], "metadata": {"source": "test"}}"#]
).pipe(
    swiftFunction: { input, output, err in
        // Transform JSON structure with type safety
        var jsonData = Data()
        
        for try await chunk in input.lines() {
            jsonData.append(contentsOf: chunk.utf8)
        }
        
        do {
            let decoder = JSONDecoder()
            let inputData = try decoder.decode(InputData.self, from: jsonData)
            
            let outputData = OutputData(
                processedItems: inputData.items.map { $0.uppercased() },
                itemCount: inputData.items.count,
                processingDate: ISO8601DateFormatter().string(from: Date())
            )
            
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let outputJson = try encoder.encode(outputData)
            let jsonString = String(data: outputJson, encoding: .utf8) ?? ""
            
            let written = try await output.write(jsonString)
            return written > 0 ? 0 : 1
        } catch {
            try await err.write("JSON transformation failed: \(error)")
            return 1
        }
    }
).finally(
    output: .string(limit: .max),
    error: .string(limit: .max)
)
```

### JSON Stream Processing
```swift
struct LogEntry: Codable {
    let timestamp: String
    let level: String
    let message: String
}

let logProcessor = pipe(
    executable: .name("tail"),
    arguments: ["-f", "/var/log/app.log"]
).pipe(
    swiftFunction: { input, output, err in
        // Process JSON log entries line by line
        for try await line in input.lines() {
            guard !line.isEmpty else { continue }
            
            do {
                let decoder = JSONDecoder()
                let logEntry = try decoder.decode(LogEntry.self, from: line.data(using: .utf8) ?? Data())
                
                // Filter for error/warning logs and format output
                if ["ERROR", "WARN"].contains(logEntry.level) {
                    let formatted = "[\(logEntry.timestamp)] \(logEntry.level): \(logEntry.message)"
                    _ = try await output.write(formatted + "\n")
                }
            } catch {
                // Skip malformed JSON lines
                continue
            }
        }
        return 0
    }
).pipe(
    executable: .name("head"),
    arguments: ["-20"]  // Limit to first 20 error/warning entries
).finally(
    output: .string(limit: .max),
    error: .string(limit: .max)
)
```

### JSON Aggregation Pipeline
```swift
struct SalesRecord: Codable {
    let product: String
    let amount: Double
    let date: String
}

struct SalesSummary: Codable {
    let totalSales: Double
    let productCounts: [String: Int]
    let averageSale: Double
}

let salesAnalyzer = pipe(
    executable: .name("cat"),
    arguments: ["sales_data.jsonl"]  // JSON Lines format
).pipe(
    swiftFunction: { input, output, err in
        // Aggregate JSON sales data with Swift collections
        var totalSales: Double = 0
        var productCounts: [String: Int] = [:]
        var recordCount = 0
        
        for try await line in input.lines() {
            guard !line.isEmpty else { continue }
            
            do {
                let decoder = JSONDecoder()
                let record = try decoder.decode(SalesRecord.self, from: line.data(using: .utf8) ?? Data())
                
                totalSales += record.amount
                productCounts[record.product, default: 0] += 1
                recordCount += 1
            } catch {
                // Log parsing errors but continue processing
                try await err.write("Failed to parse line: \(line)\n")
            }
        }
        
        let summary = SalesSummary(
            totalSales: totalSales,
            productCounts: productCounts,
            averageSale: recordCount > 0 ? totalSales / Double(recordCount) : 0
        )
        
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted
            let summaryJson = try encoder.encode(summary)
            let jsonString = String(data: summaryJson, encoding: .utf8) ?? ""
            
            let written = try await output.write(jsonString)
            return written > 0 ? 0 : 1
        } catch {
            try await err.write("Failed to encode summary: \(error)")
            return 1
        }
    }
).finally(
    output: .string(limit: .max),
    error: .string(limit: .max)
)
```

### Combining Swift Functions with External Tools
```swift
struct User: Codable {
    let id: Int
    let username: String
    let email: String
}

let usersJson = #"[{"id": 1, "username": "alice", "email": "alice@example.com"}, {"id": 2, "username": "bob", "email": "bob@example.com"}, {"id": 3, "username": "charlie", "email": "charlie@example.com"}, {"id": 6, "username": "dave", "email": "dave@example.com"}]"#

let userProcessor = pipe(
    executable: .name("echo"),
    arguments: [usersJson]
).pipe(
    swiftFunction: { input, output, err in
        // Decode JSON and filter with Swift
        var jsonData = Data()
        
        for try await chunk in input.lines() {
            jsonData.append(contentsOf: chunk.utf8)
        }
        
        do {
            let decoder = JSONDecoder()
            let users = try decoder.decode([User].self, from: jsonData)
            
            // Filter and transform users with Swift
            let filteredUsers = users.filter { $0.id <= 5 }
            let usernames = filteredUsers.map { $0.username }.joined(separator: "\n")
            
            let written = try await output.write(usernames)
            return written > 0 ? 0 : 1
        } catch {
            try await err.write("JSON decoding failed: \(error)")
            return 1
        }
    }
).pipe(
    executable: .name("sort")  // Use external tool for sorting
).finally(
    output: .string(limit: .max),
    error: .string(limit: .max)
)
```

### Benefits of Swift Functions in Pipelines

1. **Type Safety**: Use Swift's `Codable` for guaranteed JSON parsing
2. **Error Handling**: Robust error handling with Swift's `do-catch`
3. **Performance**: In-memory processing without external tool overhead
4. **Integration**: Seamless mixing with traditional Unix tools
5. **Maintainability**: Readable, testable Swift code within pipelines

## ProcessStageOptions Reference

```swift
// Predefined options
ProcessStageOptions.default        // .separate - keep stdout/stderr separate
ProcessStageOptions.stderrToStdout // .replaceStdout - stderr becomes stdout
ProcessStageOptions.mergeErrors    // .mergeWithStdout - both to same destination

// Custom options
ProcessStageOptions(errorRedirection: .separate)
ProcessStageOptions(errorRedirection: .replaceStdout)
ProcessStageOptions(errorRedirection: .mergeWithStdout)
```

## Type Safety

The generic parameters ensure compile-time safety:

```swift
// Input type from first process
PipeConfiguration<NoInput, StringOutput<UTF8>, DiscardedOutput>

// Intermediate processes can have different error handling
// Final process can change output/error types
pipeline |> finally(
    executable: .name("wc"),
    output: .string(limit: .max),         // New output type
    error: .fileDescriptor(errorFile)     // New error type  
) // Result: PipeConfiguration<NoInput, StringOutput<UTF8>, FileDescriptorOutput>
```

## Migration from Old API

**❌ OLD - Repetitive and no error control:**
```swift
let oldWay = PipeConfiguration(
    executable: .name("echo"),
    arguments: ["data"],
    input: .none,
    output: .string(limit: .max),  // ❌ misleading - gets replaced
    error: .discarded
).pipe(
    executable: .name("sort"), 
    output: .string(limit: .max)   // ❌ misleading - gets replaced
).pipe(
    executable: .name("head"), 
    output: .string(limit: .max)   // ❌ misleading - gets replaced  
).pipe(
    executable: .name("wc"), 
    output: .string(limit: .max)   // ✅ only this matters
)
// No control over stderr handling
```

**✅ NEW - Clear and flexible:**
```swift
let newWay = pipe(
    executable: .name("echo"),
    arguments: ["data"]            // ✅ I/O specified at the end
) | process(
    executable: .name("sort"), 
    options: .mergeErrors          // ✅ clear error control options
) | .name("head")                  // ✅ clear - passing through
  |> finally(                      // ✅ clear - final output specified here
    executable: .name("wc"),
    output: .string(limit: .max),
    error: .discarded
)
```

This design provides a clean, type-safe, and highly flexible API for process pipelines that mirrors familiar shell syntax while providing fine-grained control over error handling that isn't possible in traditional shell pipelines.