import Foundation

/// 编译时由 dev_flow.sh 注入的版本信息（build 前 git hash 写入）。
/// App 启动时写到 Documents/version.txt，供 install 后拉回确认装的代码版本。
enum AppVersion {
    /// git short hash，dev_flow.sh build 前注入。占位 "unset" 表示未注入。
    static let buildHash: String = "unset"
    /// 构建时间，dev_flow.sh 注入。
    static let buildTime: String = "unset"
    /// 源码指纹（关键 .swift 文件 mtime md5），反映工作区真实状态，防增量编译缓存。
    static let srcFingerprint: String = "unset"

    /// 写版本标记到 Documents，供外部拉取确认设备上 App 的代码版本。
    static func writeMarker() {
        let dir = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        guard let dir else { return }
        let content = "buildHash=\(buildHash)\nbuildTime=\(buildTime)\nsrcFingerprint=\(srcFingerprint)\n"
        try? content.write(toFile: dir + "/version.txt", atomically: true, encoding: .utf8)
    }
}
