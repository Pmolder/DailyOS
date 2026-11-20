import Foundation
import UIKit

struct GeminiVerificationResult {
    let verified: Bool
    let reason: String
    let usedOfflineFallback: Bool
}

/// Sends a live camera JPEG + active Focus task context to `gemini-2.5-flash`
/// to verify whether the user is genuinely performing their scheduled task.
enum GeminiVisionService {
    private static let endpointBase = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"

    static func verifyFocusPhoto(
        image: UIImage,
        taskTitle: String,
        taskDescription: String
    ) async -> GeminiVerificationResult {
        let apiKey = KeychainService.loadGeminiAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)

        // Offline / No-Key Testing Fallback
        if KeychainService.offlineVisionFallbackEnabled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            return GeminiVerificationResult(
                verified: true,
                reason: "Offline fallback test mode enabled: live camera snapshot accepted for '\(taskTitle)'.",
                usedOfflineFallback: true
            )
        }

        guard !apiKey.isEmpty else {
            return GeminiVerificationResult(
                verified: false,
                reason: "No Gemini API key configured. Open Settings to add your key or enable Offline Test Mode.",
                usedOfflineFallback: false
            )
        }

        guard let resized = resizeImage(image, maxDimension: 1024),
              let jpegData = resized.jpegData(compressionQuality: 0.75) else {
            return GeminiVerificationResult(
                verified: false,
                reason: "Could not encode live camera photo to JPEG.",
                usedOfflineFallback: false
            )
        }

        let base64Image = jpegData.base64EncodedString()
        let prompt = """
        You are a strict personal accountability verifier.
        Current scheduled focus task: "\(taskTitle)"
        Task details: "\(taskDescription.isEmpty ? "No extra details provided." : taskDescription)"

        Inspect this live camera photo taken right now. Determine whether the photo plausibly proves the user is actively at or engaged in this task (e.g., workspace, notebook, laptop, classroom, gym, desk, tools relevant to the task — NOT a blank black/covered camera lens, bed sheets while supposed to study/work, or obvious cheat photo).

        Respond strictly in this exact two-line format and nothing else:
        VERIFIED: true
        REASON: <one concise sentence explaining why>

        Or if rejected:
        VERIFIED: false
        REASON: <one concise sentence explaining why>
        """

        let body: [String: Any] = [
            "contents": [
                [
                    "parts": [
                        ["text": prompt],
                        [
                            "inline_data": [
                                "mime_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ]
                    ]
                ]
            ],
            "generationConfig": [
                "temperature": 0.1,
                "maxOutputTokens": 120
            ]
        ]

        guard var components = URLComponents(string: endpointBase) else {
            return GeminiVerificationResult(verified: false, reason: "Invalid Gemini endpoint URL.", usedOfflineFallback: false)
        }
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
        guard let url = components.url else {
            return GeminiVerificationResult(verified: false, reason: "Failed to build Gemini API URL.", usedOfflineFallback: false)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 18

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return GeminiVerificationResult(verified: false, reason: "Invalid network response from Gemini.", usedOfflineFallback: false)
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errBody = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                let snippet = String(errBody.prefix(160))
                return GeminiVerificationResult(
                    verified: false,
                    reason: "Gemini API error (HTTP \(httpResponse.statusCode)): \(snippet)",
                    usedOfflineFallback: false
                )
            }

            let rawText = extractCandidateText(from: data)
            return parseVerificationResponse(rawText)
        } catch {
            return GeminiVerificationResult(
                verified: false,
                reason: "Network error contacting Gemini: \(error.localizedDescription)",
                usedOfflineFallback: false
            )
        }
    }

    private static func extractCandidateText(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            return ""
        }
        return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func parseVerificationResponse(_ text: String) -> GeminiVerificationResult {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            return GeminiVerificationResult(
                verified: false,
                reason: "Gemini returned an empty response. Retake photo clearly showing your task.",
                usedOfflineFallback: false
            )
        }

        let upper = cleaned.uppercased()
        let isVerified = upper.contains("VERIFIED: TRUE") || upper.contains("\"VERIFIED\": TRUE") || upper.contains("VERIFIED:TRUE")

        var reason = ""
        for line in cleaned.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.uppercased().hasPrefix("REASON:") {
                reason = String(trimmed.dropFirst("REASON:".count)).trimmingCharacters(in: .whitespaces)
                break
            }
        }

        if reason.isEmpty {
            reason = cleaned
                .replacingOccurrences(of: "VERIFIED: true", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "VERIFIED: false", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if reason.isEmpty {
            reason = isVerified ? "Photo verified for active focus block." : "Photo did not prove active engagement with the task."
        }

        return GeminiVerificationResult(
            verified: isVerified,
            reason: reason,
            usedOfflineFallback: false
        )
    }

    private static func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }

        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
