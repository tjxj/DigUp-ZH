import Foundation
import Testing
@testable import DigUpKit

@Suite struct QwenContractTests {
    @Test func usesRequestedQwenWeights() {
        #expect(ModelFiles.repository == "DevQuasar/Qwen.Qwen3-VL-Embedding-2B-GGUF")
        #expect(ModelFiles.text.name == "Qwen.Qwen3-VL-Embedding-2B.Q4_K_M.gguf")
        #expect(ModelFiles.media.name == "mmproj-Qwen.Qwen3-VL-Embedding-2B.f16.gguf")
        #expect(ModelFiles.totalBytes == 1_926_805_664)
        #expect(Vectors.dimension == 2048)
        #expect(ModelFiles.installed.path.contains("DigUp-ZH"))
    }

    @Test func queriesAndDocumentsUseTheOfficialEmbeddingTemplate() {
        let prefix = "<|im_start|>system\nRepresent the user's input.<|im_end|>\n<|im_start|>user\n"
        let suffix = "<|im_end|>\n<|im_start|>assistant\n"
        #expect(Prompts.query("报销发票") == prefix + "报销发票" + suffix)
        #expect(Prompts.document(title: nil, text: "员工报销流程") == prefix + "员工报销流程" + suffix)
        #expect(Prompts.document(title: "管理制度", text: "员工报销流程").contains("管理制度\n员工报销流程"))
        #expect(Prompts.codeQuery("自动重试").hasSuffix(suffix))
    }

    @Test func audioIsExcludedFromTheVisualModel() {
        #expect(Rules.classify(URL(fileURLWithPath: "/Users/Shared/meeting.wav"),
                               type: .audio, options: IndexOptions()) != .index(.audio))
    }
}
