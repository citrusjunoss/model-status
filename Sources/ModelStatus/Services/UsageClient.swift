import Foundation

enum UsageClientError: Error {
    case cancelled
    case unauthorized
    case transport
    case invalidResponse
}

final class UsageClient {
    func makeTask(
        apiKey: String,
        date: Date = Date(),
        completion: @escaping (Result<UsageResponse, UsageClientError>) -> Void
    ) -> URLSessionDataTask {
        var components = URLComponents(url: AppConfig.usageURL, resolvingAgainstBaseURL: false)!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let formattedDate = formatter.string(from: date)
        components.queryItems = [
            URLQueryItem(name: "start_date", value: formattedDate),
            URLQueryItem(name: "end_date", value: formattedDate),
            URLQueryItem(name: "days", value: "1"),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier)
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        return URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                completion(.failure(.cancelled))
                return
            }
            guard error == nil else {
                completion(.failure(.transport))
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode
            guard statusCode != 401, statusCode != 403 else {
                completion(.failure(.unauthorized))
                return
            }
            guard let statusCode,
                  (200..<300).contains(statusCode),
                  let data,
                  let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
                completion(.failure(.invalidResponse))
                return
            }
            completion(.success(decoded))
        }
    }
}
