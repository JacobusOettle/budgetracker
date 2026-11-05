import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device language model (Apple Intelligence, iOS 26+), used for
/// categorising payments without an API key. Nothing leaves the phone.
///
/// Its context is about 4 096 tokens, so it gets a shorter payment history
/// than cloud models. In the background Apple may throttle it when the phone
/// is busy; such payments stay Unassigned and are retried when Tally opens.
enum OnDeviceAI {
    /// nil when ready, otherwise why it can't be used.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible:
                    return "This iPhone doesn't support Apple Intelligence (an iPhone 15 Pro or newer is needed)."
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence in Settings → Apple Intelligence & Siri."
                case .modelNotReady:
                    return "Apple Intelligence is still getting ready (downloading). Try again later."
                @unknown default:
                    return "Apple Intelligence isn't available right now."
                }
            }
        }
        return "Needs iOS 26 or later."
        #else
        return "This build of Tally doesn't include Apple Intelligence support."
        #endif
    }

    static var isAvailable: Bool { unavailableReason == nil }

    static func makeClient() -> LLMCompleting? {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isAvailable {
            return OnDeviceLLMClient()
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
/// The answer shape, filled in by guided generation (always valid).
@available(iOS 26.0, *)
@Generable
struct OnDeviceCategoryAnswer {
    @Guide(description: "One budget name exactly as listed, or an empty string if unsure")
    var budget: String

    @Guide(description: "How sure you are, from 0 to 1")
    var confidence: Double

    @Guide(description: "Why, in at most 12 words")
    var reason: String
}

@available(iOS 26.0, *)
struct OnDeviceLLMClient: LLMCompleting {
    /// Keeps the prompt well inside the ~4 096-token context.
    var maxHistory: Int { 25 }

    func complete(_ prompt: CategorizationPrompt) async throws -> String {
        // A fresh session per payment, so each one starts with an empty context.
        let session = LanguageModelSession(instructions: prompt.system)
        do {
            let response = try await session.respond(to: prompt.user, generating: OnDeviceCategoryAnswer.self)
            let answer = response.content
            let object: [String: Any] = [
                "budget": answer.budget,
                "confidence": answer.confidence,
                "reason": answer.reason,
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            return String(decoding: data, as: UTF8.self)
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .rateLimited:
                throw LLMError.temporarilyUnavailable("Apple Intelligence is busy")
            case .assetsUnavailable:
                throw LLMError.temporarilyUnavailable("Apple Intelligence isn't ready")
            default:
                throw error
            }
        }
    }
}
#endif
