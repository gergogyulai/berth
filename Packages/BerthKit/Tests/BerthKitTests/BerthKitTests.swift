import Foundation
import Testing
@testable import BerthKit

@Suite struct SMBURLTests {
    @Test func buildsRegisteredURLWithDomainAndPort() {
        let url = SMBURL.make(address: ServerAddress(host: "nas.local", port: 4455), share: "Media Files",
                              auth: .registered, username: "jo@home", domain: "WORK")
        #expect(url?.absoluteString == "smb://WORK;jo%40home@nas.local:4455/Media%20Files")
    }

    @Test func buildsGuestAndIPv6URLs() {
        #expect(SMBURL.make(address: ServerAddress(host: "10.0.0.2"), share: "pub", auth: .guest, username: "", domain: "")?
            .absoluteString == "smb://guest:@10.0.0.2/pub")
        #expect(SMBURL.make(address: ServerAddress(host: "fd7a:115c:a1e0::1"), share: "x", auth: .anonymous, username: "", domain: "")?
            .absoluteString == "smb://[fd7a:115c:a1e0::1]/x")
    }

    @Test func parsesMountSources() {
        let p = SMBURL.parse("//GUEST:@Windows%2011._smb._tcp.local/%5BC%5D%20Windows%2011")
        #expect(p?.host == "Windows 11._smb._tcp.local")
        #expect(p?.share == "[C] Windows 11")
        #expect(p?.username == "GUEST")
        let q = SMBURL.parse("smb://CORP;alice@files.example.com:1445/team/sub")
        #expect(q == SMBURL.Parsed(host: "files.example.com", port: 1445, share: "team", username: "alice", domain: "CORP"))
    }

    @Test func hostMatchingIsLoose() {
        #expect(SMBURL.hostsMatch("NAS.local.", "nas"))
        #expect(SMBURL.hostsMatch("nas._smb._tcp.local", "NAS.local"))
        #expect(!SMBURL.hostsMatch("nas2", "nas"))
    }
}

@Suite struct ClassifierTests {
    @Test func classifiesTailscale() {
        #expect(AddressClassifier.classify("100.101.102.103") == .tailscale)
        #expect(AddressClassifier.classify("100.128.0.1") == .lan)
        #expect(AddressClassifier.classify("nas.tail1234.ts.net") == .tailscale)
        #expect(AddressClassifier.classify("fd7a:115c:a1e0:ab12::1") == .tailscale)
        #expect(AddressClassifier.classify("192.168.1.10") == .lan)
        #expect(AddressClassifier.classify("nas.local") == .lan)
    }
}

@Suite struct RuleTests {
    let lan = ServerAddress(host: "192.168.1.5")
    let ts = ServerAddress(host: "nas.tail.ts.net")

    func share(_ mode: NetworkRule.Mode) -> Share {
        Share(addresses: [lan, ts], shareName: "s", networkRule: NetworkRule(mode: mode))
    }

    @Test func homeOrTailscale() {
        let home = HomeNetworks(ssids: ["Home"])
        var net = NetworkSnapshot(isOnline: true, usesWiFi: true, ssid: "Home", tailscale: TailscaleStatus(isUp: true))
        #expect(RuleEvaluator.evaluate(share: share(.trustedOrTailscale), network: net, homeNetworks: home) == .allowed([lan, ts]))
        net.ssid = "Cafe"
        #expect(RuleEvaluator.evaluate(share: share(.trustedOrTailscale), network: net, homeNetworks: home) == .allowed([ts]))
        net.tailscale.isUp = false
        #expect(RuleEvaluator.evaluate(share: share(.trustedOrTailscale), network: net, homeNetworks: home) == .needsTailscale)
    }

    @Test func trustedOnlyAndWired() {
        let home = HomeNetworks(ssids: ["Home"], wiredIsHome: true)
        let away = NetworkSnapshot(isOnline: true, usesWiFi: true, ssid: "Cafe")
        if case .blocked = RuleEvaluator.evaluate(share: share(.trustedOnly), network: away, homeNetworks: home) {} else {
            Issue.record("expected blocked")
        }
        let wired = NetworkSnapshot(isOnline: true, usesWired: true)
        #expect(RuleEvaluator.evaluate(share: share(.trustedOnly), network: wired, homeNetworks: home) == .allowed([lan]))
    }
}

@Suite struct NSMBConfTests {
    @Test func roundTripsAndPreservesUnknownLines() {
        let text = "# my config\n[default]\nsigning_required=yes\n; keep me\nfoo=bar\n[NAS]\nmc_on=no\n"
        var conf = NSMBConf(parsing: text)
        #expect(conf.serialized() == text)
        conf.withSection(named: "nas") { $0["mc_on"] = "yes"; $0["soft"] = "yes" }
        conf.withSection(named: "OTHER") { $0["notify_off"] = "yes" }
        let out = conf.serialized()
        #expect(out.contains("[NAS]\nmc_on=yes\nsoft=yes\n"))
        #expect(out.contains("; keep me\nfoo=bar"))
        #expect(out.hasSuffix("[OTHER]\nnotify_off=yes\n"))
    }

    @Test func presetsApplyAndAreDetected() {
        var section = NSMBConf.Section(name: "NAS")
        section["custom"] = "1"
        PerformancePreset.tailscaleWAN.apply(to: &section)
        #expect(PerformancePreset.matching(section) == .tailscaleWAN)
        #expect(section["custom"] == "1")
        PerformancePreset.fastLAN.apply(to: &section)
        #expect(section["dir_cache_max"] == nil)
        #expect(PerformancePreset.matching(section) == .fastLAN)
    }
}

@Suite struct MiscTests {
    @Test func backoffGrowsAndCaps() {
        let b = Backoff(base: 2, maximum: 60, jitter: 0)
        #expect(b.delay(forAttempt: 1, random: 0) == 2)
        #expect(b.delay(forAttempt: 4, random: 0) == 16)
        #expect(b.delay(forAttempt: 20, random: 0) == 60)
    }

    @Test func wakeOnLAN() {
        #expect(WakeOnLAN.parseMAC("AA:bb:cc:dd:ee:ff") == [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff])
        #expect(WakeOnLAN.parseMAC("aabb.ccdd.eeff") != nil)
        #expect(WakeOnLAN.parseMAC("aa:bb:cc") == nil)
        #expect(WakeOnLAN.magicPacket(for: [1, 2, 3, 4, 5, 6]).count == 102)
    }

    @Test func slugAndResolve() {
        var config = Configuration()
        config.shares = [Share(displayName: "NAS — Média", shareName: "media")]
        #expect(config.shares[0].slug == "nas-media")
        #expect(config.resolveShare("nas-media")?.shareName == "media")
        #expect(config.resolveShare("NAS — Média") != nil)
    }

    @Test func lenientDecoding() throws {
        let json = #"{"shares":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","shareName":"x","unknownKey":1}]}"#
        let config = try JSONDecoder().decode(Configuration.self, from: Data(json.utf8))
        #expect(config.shares.first?.options.softMount == true)
        #expect(config.preferences.probeInterval == 20)
    }

    @Test func extractsURLsFromBookmarkBytes() {
        let data = Data("junk\0smb://me@1.2.3.4/data\0more".utf8)
        #expect(SharedFileList.extractURLs(from: data, scheme: "smb://") == ["smb://me@1.2.3.4/data"])
    }
}
