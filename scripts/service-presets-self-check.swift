import CoreKit

@main
struct ServicePresetsSelfCheck {
    static func main() {
        func id(_ address: String, _ provider: StorageProvider? = nil) -> String? { ServicePreset.match(address, provider: provider)?.id }
        precondition(id("https://fsn1.your-objectstorage.com") == "hetzner-object")
        precondition(id("https://abc.eu.r2.cloudflarestorage.com") == "r2")
        precondition(id("https://cloud.example.com/remote.php/webdav") == "owncloud")
        precondition(id("https://cloud.example.com/remote.php/dav/files/me") == "nextcloud")
        precondition(id("me@zh1234.rsync.net") == "rsync-net")
        precondition(id("acct.file.core.windows.net") == "azure-files")
        precondition(id("x9z1.va.idrivee2-12.com") == "idrive")
        precondition(id("https://flexo.io") == nil && id("https://notpcloud.com") == nil)
        precondition(id("https://app.koofr.net/dav/Koofr", .s3) == nil)
        let regions = ["https://s3.us-west-2.amazonaws.com": "us-west-2", "https://s3.amazonaws.com": "us-east-1",
                       "https://nbg1.your-objectstorage.com": "nbg1", "https://sos-de-fra-1.exo.io": "de-fra-1",
                       "https://s3.fr-par.scw.cloud": "fr-par", "https://s3.gra.io.cloud.ovh.net": "gra",
                       "https://gateway.storjshare.io": "global", "https://abc.r2.cloudflarestorage.com": "auto",
                       "https://s3.eu-central-1.minio.example.com": "eu-central-1"]
        for (endpoint, region) in regions { precondition(ServicePreset.region(for: endpoint) == region, endpoint) }
        precondition(ServicePreset.region(for: "https://minio.example.com") == nil)
        for provider in [StorageProvider.s3, .webdav, .sftp, .smb] {
            precondition(ServicePreset.generic(provider).isGeneric)
            precondition(Set(ServicePreset.presets(for: provider).map(\.id)).count == ServicePreset.presets(for: provider).count)
        }
        print("Service presets self-check passed: address matching, signing regions and one generic choice per protocol.")
    }
}
