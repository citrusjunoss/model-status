import Foundation

struct ProbeResult {
    let succeeded: Bool
    let latencyMilliseconds: Int?
}

final class ProbeClient {
    func makeTask(
        model: ModelDefinition,
        apiKey: String,
        completion: @escaping (ProbeResult) -> Void
    ) -> URLSessionDataTask {
        var request = URLRequest(
            url: AppConfig.probeURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: AppConfig.probeTimeout
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        request.setValue("model-status/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model.id,
            "input": "仅回复 OK",
            "reasoning": ["effort": "low"],
            "max_output_tokens": 32,
            "store": false
        ])

        let started = DispatchTime.now().uptimeNanoseconds
        return URLSession.shared.dataTask(with: request) { data, response, error in
            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            let succeeded = error == nil && data != nil && statusCode.map { (200..<300).contains($0) } == true
            completion(ProbeResult(
                succeeded: succeeded,
                latencyMilliseconds: succeeded ? elapsed : nil
            ))
        }
    }
}
