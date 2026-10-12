import Foundation
import Testing
import DigUpKit
@testable import LlamaRuntime

@Suite(.serialized) struct QwenRuntimeTests {
    @Test func runtimeDeclaresQwen() {
        #expect(LlamaEmbedder.modelInfo.model == "Qwen/Qwen3-VL-Embedding-2B")
        #expect(LlamaEmbedder.modelInfo.dim == 2048)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_REAL_MODEL_TESTS"] == "1"))
    func chineseMeaningAndRepeatedInputsAreCorrect() throws {
        let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: true)
        defer { embedder.close() }
        let inputs = [Prompts.query("员工出差花费怎么报销"),
                      Prompts.document(title: nil, text: "差旅费用报销办法：员工出差后的交通费和住宿费凭发票申请报销。"),
                      Prompts.document(title: nil, text: "番茄炒蛋的做法：鸡蛋打散，西红柿切块，下锅翻炒。")]
        let v = try embedder.embedTexts(inputs)
        #expect(v.count == 3)
        for vector in v {
            #expect(vector.count == 2048)
            #expect(vector.allSatisfy { $0.isFinite })
            #expect(abs(Self.dot(vector, vector) - 1) < 0.001)
        }
        #expect(Self.dot(v[0], v[1]) > Self.dot(v[0], v[2]) + 0.10)
        let repeatVector = try embedder.embedTexts([inputs[0]])[0]
        #expect(Self.dot(v[0], repeatVector) > 0.9999)
        let rejected = try embedder.embedAudio(["/not/an/audio.wav"])
        #expect(rejected.first?.vector == nil)
        #expect(rejected.first?.error?.contains("音频") == true)
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float { zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DIGUP_REAL_MODEL_TESTS"] == "1"))
    func chineseQueryFindsImageContent() throws {
        let embedder = try LlamaEmbedder(models: LlamaModels.locate(), textOnly: false)
        defer { embedder.close() }
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Reference")
        let outputs = try embedder.embedImages([folder.appendingPathComponent("photo.jpg").path,
                                                folder.appendingPathComponent("screen.png").path], budget: 280)
        let landscape = try #require(outputs[0].vector)
        let screen = try #require(outputs[1].vector)
        let queries = try embedder.embedTexts([Prompts.query("蓝天太阳下的绿色山丘和树"),
                                              Prompts.query("带侧边栏和蓝色按钮的网页截图")])
        print("Chinese image cosines:", queries.map { [Self.dot($0, landscape), Self.dot($0, screen)] })
        #expect(Self.dot(queries[0], landscape) > Self.dot(queries[0], screen) + 0.1)
        #expect(Self.dot(queries[1], screen) > Self.dot(queries[1], landscape) + 0.1)
        #expect(abs(Self.dot(landscape, landscape) - 1) < 0.001)
        let repeated = try #require(embedder.embedImages([folder.appendingPathComponent("photo.jpg").path], budget: 280)[0].vector)
        #expect(Self.dot(landscape, repeated) > 0.9999)
    }
}
