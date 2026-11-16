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
    @Test func newShareColorsAvoidOnesInUse() {
        typealias Color = ShareIcon.IconColor
        let allButMint = Color.allCases.filter { $0 != .mint }
        #expect(Color.random(avoiding: allButMint) == .mint)

        // With every color taken, it falls back to the least used.
        let pinkTwice = Color.allCases + Color.allCases.filter { $0 != .pink }
        #expect(Color.random(avoiding: pinkTwice) == .pink)

        let unused = Set(Color.allCases).subtracting([.blue, .red])
        for _ in 0..<100 { #expect(unused.contains(Color.random(avoiding: [.blue, .red]))) }
    }

    @Test func findsTheAddressAMountUses() {
        var share = Share()
        share.addresses = [
            ServerAddress(host: "nas.local", port: 1445),
            ServerAddress(host: "10.0.0.5", kind: .tailscale),
        ]
        #expect(share.address(matchingHost: "NAS._smb._tcp.local")?.display == "nas.local:1445")
        #expect(share.address(matchingHost: "10.0.0.5")?.resolvedKind == .tailscale)
        #expect(share.address(matchingHost: "other.local") == nil)
    }

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

@MainActor @Suite struct MountGateTests {
    @Test func runsOneAtATimeInOrder() async {
        let gate = MountGate()
        var order: [Int] = []
        #expect(await gate.acquire())
        let second = Task { @MainActor in
            #expect(await gate.acquire())
            order.append(2)
            gate.release()
        }
        let third = Task { @MainActor in
            await Task.yield()
            #expect(await gate.acquire())
            order.append(3)
            gate.release()
        }
        for _ in 0..<5 { await Task.yield() }
        #expect(order.isEmpty)
        gate.release()
        await second.value
        await third.value
        #expect(order == [2, 3])
    }

    @Test func cancelledWaiterGivesUpItsPlace() async {
        let gate = MountGate()
        #expect(await gate.acquire())
        let waiter = Task { @MainActor in await gate.acquire() }
        for _ in 0..<5 { await Task.yield() }
        waiter.cancel()
        #expect(await waiter.value == false)
        gate.release()
        // Still free: the cancelled waiter must not have been handed the gate.
        #expect(await gate.acquire())
    }
}

@Suite struct RestartBudgetTests {
    @Test func limitsRestartsWithinTheWindow() {
        var budget = RestartBudget(limit: 2, window: 100)
        let start = Date()
        let results = [0, 1, 2, 100].map { budget.consume(now: start.addingTimeInterval($0)) }
        #expect(results == [true, true, false, true])
    }
}

@Suite struct MountTableThreadingTests {
    @Test func canBeReadFromManyThreadsAtOnce() {
        DispatchQueue.concurrentPerform(iterations: 2_000) { _ in
            _ = MountTable.smbMounts()
        }
    }
}

@Suite struct DuplicateMountTests {
    let share = Share(addresses: [ServerAddress(host: "192.168.1.54"), ServerAddress(host: "nas.tail.ts.net")],
                      shareName: "files", auth: .registered, username: "gergo")

    func entry(_ point: String, host: String = "192.168.1.54", share: String = "files", user: String = "gergo") -> MountTable.Entry {
        MountTable.Entry(mountPoint: point, source: "", host: host, share: share, username: user, ownerUID: getuid())
    }

    @Test func findsUntrackedCopiesOnAnyAddress() {
        let entries = [entry("/Volumes/files"), entry("/Volumes/files-1"), entry("/Volumes/files-2", host: "nas.tail.ts.net")]
        let found = MountTable.duplicates(of: share, in: entries, excluding: ["/Volumes/files"]).map(\.mountPoint)
        #expect(found == ["/Volumes/files-1", "/Volumes/files-2"])
    }

    @Test func leavesOtherSharesServersAndUsersAlone() {
        let entries = [entry("/Volumes/other", share: "other"), entry("/Volumes/x", host: "10.0.0.1"), entry("/Volumes/guest", user: "GUEST")]
        #expect(MountTable.duplicates(of: share, in: entries, excluding: []).isEmpty)
    }

    @Test func ignoresSharesWithoutAnAccount() {
        var guest = share
        guest.auth = .guest
        #expect(MountTable.duplicates(of: guest, in: [entry("/Volumes/files")], excluding: []).isEmpty)
    }
}

@Suite struct DeadPinTests {
    var shares: [Share] { [Share(addresses: [ServerAddress(host: "192.168.1.54")], shareName: "files")] }
    let url = "smb://gergo@192.168.1.54/files"

    @Test func matchesUnmountedVolumesOfOurShares() {
        #expect(SharedFileList.isDeadPin(path: "/Volumes/files", urls: [url], shares: shares, mounted: []))
    }

    @Test func keepsEverythingElse() {
        #expect(!SharedFileList.isDeadPin(path: "/Volumes/files", urls: [url], shares: shares, mounted: ["/Volumes/files"]))
        #expect(!SharedFileList.isDeadPin(path: "/Volumes/USB DISK", urls: [], shares: shares, mounted: []))
        #expect(!SharedFileList.isDeadPin(path: "/Volumes/media", urls: ["smb://gergo@192.168.1.54/media"], shares: shares, mounted: []))
        #expect(!SharedFileList.isDeadPin(path: "/Users/gergo/files", urls: [url], shares: shares, mounted: []))
    }
}

@Suite struct StuckMountPreferenceTests {
    @Test func defaultsToOnForExistingConfigs() throws {
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(prefs.restartStuckMountService)
    }
}

@Suite struct LenientConfigTests {
    @Test func oneDamagedShareDoesNotDropTheOthers() throws {
        let json = """
        {"shares": [
            {"id": "11111111-1111-1111-1111-111111111111", "shareName": "good"},
            {"id": "not-a-uuid", "shareName": "bad"},
            "garbage",
            {"id": "22222222-2222-2222-2222-222222222222", "shareName": "also good", "groupID": 7}
        ]}
        """
        let config = try ConfigStore.decode(Data(json.utf8))
        #expect(config.shares.map(\.shareName) == ["good", "also good"])
        #expect(config.shares.last?.groupID == nil)
    }

    @Test func timingsAreKeptInAUsableRange() throws {
        let json = #"{"probeInterval": 0, "probeTimeout": -4, "mountTimeout": 0, "maxRetryDelay": 1, "mountAllHotKey": "oops"}"#
        let prefs = try JSONDecoder().decode(Preferences.self, from: Data(json.utf8))
        #expect(prefs.probeInterval == 5)
        #expect(prefs.probeTimeout == 1)
        #expect(prefs.mountTimeout == 5)
        #expect(prefs.maxRetryDelay == 10)
        #expect(prefs.mountAllHotKey == nil)
        // Values the settings offer pass through untouched.
        let normal = try JSONDecoder().decode(Preferences.self, from: Data(#"{"staleGracePeriod": 0, "mountTimeout": 60}"#.utf8))
        #expect(normal.staleGracePeriod == 0)
        #expect(normal.mountTimeout == 60)
    }
}

@Suite struct CustomMountPointTests {
    func entry(_ point: String, share: String = "files", host: String = "192.168.1.54") -> MountTable.Entry {
        MountTable.Entry(mountPoint: point, source: "", host: host, share: share, username: "gergo", ownerUID: getuid())
    }

    @Test func matchesAFolderWrittenWithATilde() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // Reached under another host name, so only the folder can identify it.
        let share = Share(addresses: [ServerAddress(host: "nas.local")], shareName: "files",
                          mountLocation: .custom(path: "~/Shares/files/"))
        let found = MountTable.find(share, in: [entry("/Volumes/other", share: "other"), entry("\(home)/Shares/files")])
        #expect(found?.mountPoint == "\(home)/Shares/files")
    }

    @Test func anotherShareInTheFolderIsNotOurs() {
        let share = Share(addresses: [ServerAddress(host: "nas.local")], shareName: "files",
                          mountLocation: .custom(path: "/Users/Shared/mnt"))
        #expect(MountTable.find(share, in: [entry("/Users/Shared/mnt", share: "media")]) == nil)
    }
}

@MainActor @Suite struct NetworkBaselineTests {
    let online = NetworkSnapshot(isOnline: true, primary: .wifi, usesWiFi: true, ssid: "Home")

    @Test func comingOnlineAfterAnOfflineLaunchIsAChange() {
        let monitor = NetworkMonitor()
        var changes = 0
        monitor.onChange = { _, _ in changes += 1 }
        #expect(!monitor.hasBaseline)
        // Offline at launch looks exactly like "haven't looked yet".
        monitor.apply(.unknown)
        #expect(monitor.hasBaseline)
        #expect(changes == 0)
        monitor.apply(online)
        #expect(changes == 1)
        monitor.apply(online)
        #expect(changes == 1)
    }

    @Test func theFirstSnapshotIsNotAChange() {
        let monitor = NetworkMonitor()
        var changes = 0
        monitor.onChange = { _, _ in changes += 1 }
        monitor.apply(online)
        #expect(changes == 0)
        #expect(monitor.snapshot == online)
    }

    @Test func becomingMeteredCountsAsAChange() {
        var metered = online
        metered.isExpensive = true
        var lowData = online
        lowData.isConstrained = true
        #expect(online.fingerprint != metered.fingerprint)
        #expect(online.fingerprint != lowData.fingerprint)
    }
}

@Suite struct ConnectReasonTests {
    @Test func onlyReturningMountsCountAsReconnects() {
        #expect(ConnectReason.reconnect.isReconnect && ConnectReason.wake.isReconnect && ConnectReason.network.isReconnect)
        #expect(!ConnectReason.user.isReconnect && !ConnectReason.launch.isReconnect && !ConnectReason.retry.isReconnect)
        #expect(!ConnectReason.user.isAutomatic && ConnectReason.retry.isAutomatic)
    }
}

@Suite struct WaitingStateTests {
    @Test func onlyIdleStatesAreRetriedByTheHealthCheck() {
        #expect(ShareState.disconnected.isWaitingForConditions)
        #expect(ShareState.paused(.offline).isWaitingForConditions)
        #expect(ShareState.paused(.networkRule("Not on a home network")).isWaitingForConditions)
        // Waking decides what comes back; errors have their own retries or need the user.
        #expect(!ShareState.paused(.sleeping).isWaitingForConditions)
        #expect(!ShareState.authFailed.isWaitingForConditions)
        #expect(!ShareState.hostUnreachable.isWaitingForConditions)
        #expect(!ShareState.tailscaleDown.isWaitingForConditions)
        #expect(!ShareState.mounted.isWaitingForConditions)
    }
}
