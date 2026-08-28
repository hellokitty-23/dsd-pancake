import Foundation

public enum LocalService {
    public static let host = "127.0.0.1"
    public static let port = AppRuntimeConfiguration.current.servicePort
    public static let url = URL(string: "http://\(host):\(port)/")!
    public static let manifestURL = url.appendingPathComponent("manifest.webmanifest")
    public static let hostAndPort = "\(host):\(port)"
}
