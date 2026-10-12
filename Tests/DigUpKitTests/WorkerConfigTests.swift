import Foundation
import Testing
@testable import DigUpKit

@Suite struct WorkerConfigTests {
    @Test func bundledHelperKeepsItsExistingProtocol() throws {
        let executable = URL(fileURLWithPath: "/Applications/DigUp-ZH.app/Contents/Helpers/digup")
        let config = WorkerConfig.helper(executable)
        #expect(config.executable == executable)
        #expect(config.arguments == ["worker"])
        #expect(try WorkerConfig.fromEnvironment([:]) == nil)
        #expect(try WorkerConfig.fromEnvironment(["DIGUP_MODELS": "/models"]) == nil)
    }

    @Test func retiredOverrideNeverStartsAnotherModel() {
        for value in ["", "/a/legacy/worker"] {
            do {
                _ = try WorkerConfig.fromEnvironment(["DIGUP_WORKER_DIR": value])
                Issue.record("A retired worker override must fail")
            } catch {
                #expect(String(describing: error).contains("DIGUP_WORKER_DIR"))
                #expect(String(describing: error).contains("Qwen3-VL-Embedding-2B"))
            }
        }
        #expect(throws: WorkerError.self) {
            try WorkerConfig.python(URL(fileURLWithPath: "/a/legacy/worker"))
        }
    }

    // These subprocesses exercise the wire protocol only; they never load or imitate a real model.
    private func worker(dimension: Int, reply: String? = nil) -> WorkerConfig {
        let ready = "{\"ready\":true,\"info\":{\"model\":\"protocol-test\",\"revision\":\"test\",\"runtime\":\"test\",\"dtype\":\"f32\",\"dim\":\(dimension),\"text_only\":true}}"
        var command = "printf '%s\\n' '\(ready)'; IFS= read -r request"
        if let reply { command += "; printf '%s\\n' '\(reply)'; IFS= read -r request" }
        return WorkerConfig(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", command])
    }

    @Test func startupRejectsAnOldEmbeddingWidth() {
        #expect(throws: WorkerError.self) {
            try EmbeddingWorker(worker(dimension: 768), textOnly: true)
        }
    }

    @Test func startupAcceptsTheCurrentEmbeddingWidth() throws {
        let process = try EmbeddingWorker(worker(dimension: Vectors.dimension), textOnly: true)
        defer { process.close() }
        #expect(process.info.dim == 2048)
    }

    @Test func repliesCannotChangeTheEmbeddingWidth() throws {
        let reply = "{\"id\":1,\"ok\":true,\"dim\":768,\"vectors\":\"\"}"
        let process = try EmbeddingWorker(worker(dimension: Vectors.dimension, reply: reply), textOnly: true)
        defer { process.close() }
        #expect(throws: WorkerError.self) { try process.embedTexts(["协议检查"]) }
    }
}
