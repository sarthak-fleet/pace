//
//  PaceFMIntentClassifierBenchmarkTests.swift
//  leanring-buddyTests
//
//  Benchmarks Apple Foundation Models intent classifier against the
//  same held-out eval set used for the TinyGPT pace-intent-router.
//  Stratified sample of 500 examples (proportional to class distribution).
//

import Foundation
import Testing
import FoundationModels
@testable import Pace

@MainActor
struct PaceFMIntentClassifierBenchmark {

    /// Sample size — 200 stratified examples. At 1 call/sec (to avoid
    /// FM rate limiting), this runs in ~4 minutes. Full 15K would take
    /// ~4 hours.
    static let sampleSize = 200

    /// Load eval data from posttrainllm/data/pace-intent-eval.jsonl
    /// and create a stratified sample.
    private func loadStratifiedSample() -> [(query: String, expected: String)] {
        let evalPath = "../../../posttrainllm/data/pace-intent-eval.jsonl"
        let resolvedPath = FileManager.default.fileSystemRepresentation(withPath: evalPath)

        guard let fileHandle = FileHandle(forReadingAtPath: evalPath) else {
            // Try absolute path as fallback
            let absPath = "/Users/sarthak/Desktop/fleet/posttrainllm/data/pace-intent-eval.jsonl"
            guard let absHandle = FileHandle(forReadingAtPath: absPath) else {
                Issue.record("Could not open eval data file")
                return []
            }
            return parseAndSample(from: absHandle)
        }
        return parseAndSample(from: fileHandle)
    }

    private func parseAndSample(from handle: FileHandle) -> [(query: String, expected: String)] {
        var byClass: [String: [(query: String, expected: String)]] = [:]
        let data = handle.readDataToEndOfFile()
        handle.closeFile()

        guard let content = String(data: data, encoding: .utf8) else {
            Issue.record("Could not decode eval data as UTF-8")
            return []
        }

        for line in content.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: String],
                  let query = json["query"],
                  let tool = json["tool"] else {
                continue
            }
            byClass[tool, default: []].append((query: query, expected: tool))
        }

        // Stratified sample proportional to class distribution
        let total = byClass.values.reduce(0) { $0 + $1.count }
        var sample: [(query: String, expected: String)] = []
        for (cls, examples) in byClass {
            let proportion = Double(examples.count) / Double(total)
            let sampleCount = max(10, Int(Double(Self.sampleSize) * proportion))
            // Take every Nth element for deterministic sampling
            let stride = max(1, examples.count / sampleCount)
            for i in Swift.stride(from: 0, to: examples.count, by: stride) {
                sample.append(examples[i])
                if sample.count >= Self.sampleSize { break }
            }
        }

        return sample
    }

    @Test
    func benchmarkFMClassifierAccuracy() async {
        guard #available(macOS 26.0, *) else {
            Issue.record("Apple Foundation Models requires macOS 26.0+")
            return
        }

        let systemModel = SystemLanguageModel.default
        guard case .available = systemModel.availability else {
            Issue.record("Apple Intelligence is not available on this Mac")
            return
        }

        let sample = loadStratifiedSample()
        guard !sample.isEmpty else {
            Issue.record("No eval data loaded")
            return
        }

        print("\n📊 FM Intent Classifier Benchmark")
        print("   Sample size: \(sample.count)")
        print("   Running Apple FM classification on each example...")

        let classifier = PaceFMIntentClassifier()
        var correct = 0
        var total = 0
        var errorCount = 0
        var perClassCorrect: [String: Int] = [:]
        var perClassTotal: [String: Int] = [:]
        var failures: [(query: String, expected: String, predicted: String)] = []
        var errorMessages: [String] = []
        let startTime = Date()

        // Capture the first 10 error messages by intercepting the
        // classifier. We can't see inside the catch block, so we
        // replicate the call here for the first few failures.
        var errorSampleCount = 0

        for (index, example) in sample.enumerated() {
            let prediction = await classifier.classify(example.query)
            let predicted = prediction.intent.rawValue

            // Count errors — FM catch block returns confidence 0
            if prediction.confidence == 0 {
                errorCount += 1
                // Capture error details for first 10 errors by making
                // a direct FM call to see the thrown error
                if errorSampleCount < 10 {
                    errorSampleCount += 1
                    if #available(macOS 26.0, *) {
                        let model = SystemLanguageModel.default
                        if case .available = model.availability {
                            let instructions = """
                            You classify a single user voice turn into ONE routing category for Pace, a macOS voice companion. Pick the most accurate route.
                            """
                            let session = LanguageModelSession(model: model, instructions: Instructions(instructions))
                            let opts = GenerationOptions(sampling: .greedy, temperature: 0, maximumResponseTokens: 30)
                            do {
                                let _ = try await session.respond(
                                    to: "user said: \"\(example.query)\"",
                                    generating: PaceFMIntentClassification.self,
                                    options: opts
                                )
                            } catch {
                                errorMessages.append("\(type(of: error)): \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }

            perClassTotal[example.expected, default: 0] += 1
            if predicted == example.expected {
                correct += 1
                perClassCorrect[example.expected, default: 0] += 1
            } else {
                failures.append((query: example.query, expected: example.expected, predicted: predicted))
            }
            total += 1

            if (index + 1) % 50 == 0 {
                let elapsed = Date().timeIntervalSince(startTime)
                let rate = Double(index + 1) / elapsed
                print("   Progress: \(index + 1)/\(sample.count) (\(String(format: "%.1f", rate)) examples/sec, \(String(format: "%.1f", Double(correct) / Double(total) * 100))% accuracy, \(errorCount) errors)")
            }

            // 1-second delay between calls to avoid rate limiting
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let accuracy = Double(correct) / Double(total)
        let meanLatencyMs = (elapsed * 1000) / Double(total)

        // Write results to file since xcodebuild swallows stdout
        let resultsPath = "/tmp/fm-intent-benchmark-results.json"
        var resultsDict: [String: Any] = [:]
        resultsDict["model"] = "apple-fm-intent-classifier"
        resultsDict["sample_size"] = total
        resultsDict["overall_accuracy"] = accuracy
        resultsDict["mean_latency_ms"] = meanLatencyMs
        resultsDict["total_time_s"] = elapsed
        resultsDict["correct"] = correct
        resultsDict["error_count"] = errorCount
        resultsDict["error_rate"] = Double(errorCount) / Double(total)
        resultsDict["note"] = "error_count = calls where FM threw and fell back to .unknown (confidence=0). If error_rate is high, accuracy is meaningless — FM isn't actually classifying."
        resultsDict["error_messages"] = errorMessages

        var perClass: [String: Any] = [:]
        let allClasses = ["chitchat", "pureKnowledge", "screenDescription", "screenAction", "research", "phoneLargeModel", "unknown"]
        for cls in allClasses {
            let c = perClassCorrect[cls, default: 0]
            let t = perClassTotal[cls, default: 0]
            let acc = t > 0 ? Double(c) / Double(t) : 0
            perClass[cls] = ["accuracy": acc, "correct": c, "count": t]
        }
        resultsDict["per_class"] = perClass

        var failuresArr: [[String: String]] = []
        for f in failures.prefix(50) {
            failuresArr.append(["query": f.query, "expected": f.expected, "predicted": f.predicted])
        }
        resultsDict["failures"] = failuresArr

        resultsDict["references"] = [
            "tinygpt_v8": ["accuracy": 0.9553, "latency_p50_ms": 3.1],
            "tinygpt_v5": ["accuracy": 0.9591, "latency_p50_ms": 4.6],
            "qwen3_4b_4bit": ["accuracy": 0.8475, "latency_p50_ms": 240]
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: resultsDict, options: .prettyPrinted),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            try? jsonString.write(toFile: resultsPath, atomically: true, encoding: .utf8)
        }

        #expect(total > 0, "Should have evaluated at least one example")
        #expect(accuracy > 0.0, "Should have gotten at least one correct")
    }
}
