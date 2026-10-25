import Foundation
import CoreKit

/// Branded services that speak one of the four protocols. A preset is only a template and some hints:
/// every connection still has to pass the connection check, including `StoreCompatibility`, before it saves.
struct ServicePreset: Identifiable, Hashable {
    /// Where the S3 signing region comes from.
    enum Region: Hashable {
        case ask
        case fixed(String)
        /// The host's nth dot-separated label, without `dropPrefix`.
        case label(Int, dropPrefix: String = "")
    }

    let id: String
    let provider: StorageProvider
    let title: String
    var endpoint = ""
    var prompt = ""
    /// Host suffixes, host fragments (no dot) or address fragments (with a slash) that identify the service.
    var matches: [String] = []
    var region: Region = .ask
    var userLabel: String?
    var secretLabel: String?
    var secretHint: String?
    var note: String?

    var isGeneric: Bool { matches.isEmpty }
    var user: String { userLabel ?? (provider == .s3 ? "Access key ID" : "User name") }
    var secret: String { secretLabel ?? (provider == .s3 ? "Secret access key" : "Password") }

    static let all: [ServicePreset] = [
        // S3-compatible
        .init(id: "s3", provider: .s3, title: "Other S3-compatible", prompt: "https://s3.example.com",
              note: "MinIO, Garage, Ceph and other servers work if they support conditional writes."),
        .init(id: "aws", provider: .s3, title: "Amazon S3", endpoint: "https://s3.us-east-1.amazonaws.com", matches: ["amazonaws.com"], region: .label(1)),
        .init(id: "r2", provider: .s3, title: "Cloudflare R2", prompt: "https://<account ID>.r2.cloudflarestorage.com",
              matches: ["r2.cloudflarestorage.com"], region: .fixed("auto")),
        .init(id: "b2", provider: .s3, title: "Backblaze B2", endpoint: "https://s3.eu-central-003.backblazeb2.com", matches: ["backblazeb2.com"], region: .label(1)),
        .init(id: "wasabi", provider: .s3, title: "Wasabi", endpoint: "https://s3.eu-central-2.wasabisys.com", matches: ["wasabisys.com"], region: .label(1)),
        .init(id: "hetzner-object", provider: .s3, title: "Hetzner Object Storage", endpoint: "https://fsn1.your-objectstorage.com",
              matches: ["your-objectstorage.com"], region: .label(0)),
        .init(id: "digitalocean", provider: .s3, title: "DigitalOcean Spaces", endpoint: "https://nyc3.digitaloceanspaces.com",
              matches: ["digitaloceanspaces.com"], region: .label(0)),
        .init(id: "akamai", provider: .s3, title: "Akamai (Linode)", endpoint: "https://us-east-1.linodeobjects.com", matches: ["linodeobjects.com"], region: .label(0)),
        .init(id: "scaleway", provider: .s3, title: "Scaleway", endpoint: "https://s3.fr-par.scw.cloud", matches: ["scw.cloud"], region: .label(1)),
        .init(id: "ovh", provider: .s3, title: "OVHcloud", endpoint: "https://s3.gra.io.cloud.ovh.net", matches: ["cloud.ovh.net"], region: .label(1)),
        .init(id: "exoscale", provider: .s3, title: "Exoscale", endpoint: "https://sos-ch-gva-2.exo.io", matches: ["exo.io"], region: .label(0, dropPrefix: "sos-")),
        .init(id: "synology-c2", provider: .s3, title: "Synology C2", endpoint: "https://eu-002.s3.synologyc2.net", matches: ["synologyc2.net"], region: .label(0)),
        .init(id: "idrive", provider: .s3, title: "IDrive e2", prompt: "https://<endpoint from your e2 dashboard>", matches: ["idrivee2"]),
        .init(id: "storj", provider: .s3, title: "Storj", endpoint: "https://gateway.storjshare.io", matches: ["storjshare.io"], region: .fixed("global")),
        .init(id: "filebase", provider: .s3, title: "Filebase", endpoint: "https://s3.filebase.com", matches: ["filebase.com"], region: .fixed("us-east-1")),
        .init(id: "tigris", provider: .s3, title: "Tigris", endpoint: "https://t3.storage.dev", matches: ["t3.storage.dev", "storage.tigris.dev"], region: .fixed("auto")),
        .init(id: "gcs", provider: .s3, title: "Google Cloud Storage", endpoint: "https://storage.googleapis.com", matches: ["storage.googleapis.com"],
              region: .fixed("auto"), userLabel: "HMAC access key", secretLabel: "HMAC secret",
              note: "Create an HMAC key in Cloud Storage › Settings › Interoperability."),
        // WebDAV
        .init(id: "webdav", provider: .webdav, title: "Other WebDAV server", prompt: "https://…"),
        .init(id: "owncloud", provider: .webdav, title: "ownCloud", prompt: "https://cloud.example.com/remote.php/webdav",
              matches: ["/remote.php/webdav", "owncloud"], secretLabel: "App password", secretHint: "Create one in ownCloud › Settings › Security"),
        .init(id: "nextcloud", provider: .webdav, title: "Nextcloud", prompt: "https://cloud.example.com/remote.php/dav/files/<user>",
              matches: ["/remote.php/", "nextcloud"], secretLabel: "App password", secretHint: "Create one in Nextcloud › Security"),
        .init(id: "pcloud", provider: .webdav, title: "pCloud", endpoint: "https://ewebdav.pcloud.com", matches: ["pcloud.com"],
              note: "EU accounts use ewebdav.pcloud.com; US accounts use webdav.pcloud.com."),
        .init(id: "koofr", provider: .webdav, title: "Koofr", endpoint: "https://app.koofr.net/dav/Koofr", matches: ["koofr.net"],
              secretLabel: "App password", secretHint: "Create one in Koofr › Preferences › Password"),
        .init(id: "kdrive", provider: .webdav, title: "Infomaniak kDrive", prompt: "https://<kDrive ID>.connect.kdrive.infomaniak.com",
              matches: ["kdrive.infomaniak.com"], secretLabel: "App password", secretHint: "Needed when two-step sign-in is on"),
        .init(id: "seafile", provider: .webdav, title: "Seafile", prompt: "https://seafile.example.com/seafdav", matches: ["/seafdav", "seafile"],
              note: "The server’s admin must turn on SeafDAV."),
        .init(id: "hidrive", provider: .webdav, title: "STRATO HiDrive", endpoint: "https://webdav.hidrive.strato.com", matches: ["hidrive.strato.com"]),
        .init(id: "yandex", provider: .webdav, title: "Yandex Disk", endpoint: "https://webdav.yandex.com", matches: ["yandex.com", "yandex.ru"],
              secretLabel: "App password", secretHint: "Create one in your Yandex ID › Security"),
        .init(id: "fastmail", provider: .webdav, title: "Fastmail Files", endpoint: "https://myfiles.fastmail.com", matches: ["myfiles.fastmail.com"],
              secretLabel: "App password", secretHint: "Give it Files (WebDAV) access"),
        .init(id: "synology-nas", provider: .webdav, title: "Synology NAS", prompt: "https://nas.example.com:5006", matches: ["synology.me"],
              note: "Install WebDAV Server from Package Center and turn on HTTPS."),
        // SFTP
        .init(id: "sftp", provider: .sftp, title: "SFTP server"),
        .init(id: "rsync-net", provider: .sftp, title: "rsync.net", prompt: "<user>@<host>.rsync.net", matches: ["rsync.net"],
              note: "Daily ZFS snapshots appear in .zfs/snapshot."),
        // SMB
        .init(id: "smb", provider: .smb, title: "NAS or Mac", prompt: "nas.local"),
        .init(id: "azure-files", provider: .smb, title: "Azure Files", prompt: "<account>.file.core.windows.net", matches: ["file.core.windows.net"],
              userLabel: "Storage account name", secretLabel: "Storage account key",
              note: "Azure Files uses port 445, which some networks block."),
    ]

    static func presets(for provider: StorageProvider) -> [ServicePreset] { all.filter { $0.provider == provider } }
    static func generic(_ provider: StorageProvider) -> ServicePreset { all.first { $0.provider == provider && $0.isGeneric }! }

    /// The named service a pasted address belongs to, if any. Nothing is contacted.
    static func match(_ address: String, provider: StorageProvider? = nil) -> ServicePreset? {
        all.first { (provider == nil || $0.provider == provider) && $0.recognizes(address) }
    }

    func recognizes(_ address: String) -> Bool {
        let lower = address.lowercased(), host = Self.host(of: address)
        return matches.contains { m in
            if m.contains("/") { return lower.contains(m) }
            if !m.contains(".") { return host.contains(m) }
            return host == m || host.hasSuffix("." + m)
        }
    }

    /// The S3 signing region an endpoint implies, when its provider puts it there.
    static func region(for endpoint: String) -> String? {
        let host = host(of: endpoint), parts = host.split(separator: ".").map(String.init)
        guard !host.isEmpty else { return nil }
        if host == "s3.amazonaws.com" || host == "s3.wasabisys.com" { return "us-east-1" }
        let rule = match(endpoint, provider: .s3)?.region ?? (parts.count >= 4 && parts[0] == "s3" ? .label(1) : .ask)
        switch rule {
        case .ask: return nil
        case .fixed(let value): return value
        case .label(let index, let prefix):
            guard index < parts.count - 2 else { return nil }
            let label = parts[index].hasPrefix(prefix) ? String(parts[index].dropFirst(prefix.count)) : parts[index]
            return label.isEmpty ? nil : label
        }
    }

    static func host(of address: String) -> String {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutUser = text.contains("://") ? text : String(text.split(separator: "@").last ?? "")
        return URL(string: withoutUser.contains("://") ? withoutUser : "https://" + withoutUser)?.host?.lowercased() ?? ""
    }
}

extension OAuthService {
    /// The name shown in lists, with Google Drive's Experimental label.
    var label: String { isExperimental ? "\(title) · Experimental" : title }
}

extension OAuthService {
    /// Web addresses that identify the service when pasted into Add storage.
    var webDomains: [String] {
        switch self {
        case .dropbox: ["dropbox.com"]
        case .onedrive: ["onedrive.live.com", "1drv.ms", "sharepoint.com"]
        case .box: ["box.com"]
        case .googledrive: ["drive.google.com"]
        }
    }
}
