import Darwin
import DiskArbitration
import Foundation

public struct USBDevice: Identifiable, Equatable, Hashable {
    public let id: String
    public let volumeURL: URL
    public let displayName: String
    public let sizeBytes: UInt64
    public let filesystem: String
    public let wholeDiskIdentifier: String?
    public init(id: String, volumeURL: URL, displayName: String, sizeBytes: UInt64, filesystem: String, wholeDiskIdentifier: String?) {
        self.id = id; self.volumeURL = volumeURL; self.displayName = displayName; self.sizeBytes = sizeBytes; self.filesystem = filesystem; self.wholeDiskIdentifier = wholeDiskIdentifier
    }
    public var isAPFS: Bool { filesystem.localizedCaseInsensitiveContains("apfs") }
}

public struct USBDevicePhysicalIdentity: Equatable {
    public let volumeUUID: String
    public let bsdName: String
    public let vendorString: String
    public let modelString: String
    public let writeProtectState: String
    public var identityID: String { "\(volumeUUID)|\(bsdName)" }

    public init(volumeUUID: String, bsdName: String, vendorString: String, modelString: String, writeProtectState: String) {
        self.volumeUUID = volumeUUID
        self.bsdName = bsdName
        self.vendorString = vendorString
        self.modelString = modelString
        self.writeProtectState = writeProtectState
    }
}

public protocol USBVaultWriting {
    var device: USBDevice { get }
    func prepareIfNeeded(formatApproved: Bool, audit: AuditLogger) throws
    func writeColdVaultAtomically(certificate: BirthCertificate,
                                  publicKey: Data,
                                  privateKeyWriter: (_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Void,
                                  usbCertificateSigner: (_ canonicalPayload: Data) throws -> Data,
                                  mnemonic: SecureMnemonic,
                                  ceremonyHash: String,
                                  ceremonyID: String,
                                  policy: PathPolicy,
                                  audit: AuditLogger) throws -> URL
    func cleanupIncompleteCeremony(policy: PathPolicy)
}

public final class USBVaultWriter: USBVaultWriting {
    public let device: USBDevice
    public init(device: USBDevice) { self.device = device }

    public func prepareIfNeeded(formatApproved: Bool, audit: AuditLogger) throws {
        if device.isAPFS { return }
        guard formatApproved else { throw CeremonyError.usbNotConfirmed }
        guard let disk = device.wholeDiskIdentifier else { throw CeremonyError.transactionFailed("Cannot format USB: no whole-disk identifier") }
        try audit.record("usb_format_started", outcome: "pending", metadata: ["disk": disk])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = ["eraseDisk", "APFS", "JARVIS_COLD", disk]
        let pipe = Pipe(); process.standardError = pipe; process.standardOutput = pipe
        try process.run(); process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw CeremonyError.transactionFailed("diskutil eraseDisk failed: \(output)") }
        try audit.record("usb_format_completed", outcome: "pass", metadata: ["disk": disk])
    }

    public func writeColdVaultAtomically(certificate: BirthCertificate,
                                         publicKey: Data,
                                         privateKeyWriter: (_ body: (UnsafeBufferPointer<UInt8>) throws -> Void) throws -> Void,
                                         usbCertificateSigner: (_ canonicalPayload: Data) throws -> Data,
                                         mnemonic: SecureMnemonic,
                                         ceremonyHash: String,
                                         ceremonyID: String,
                                         policy: PathPolicy,
                                         audit: AuditLogger) throws -> URL {
        let root = device.volumeURL
        let staging = root.appendingPathComponent(".jarvis_birth_staging", isDirectory: true)
        let vault = root.appendingPathComponent("JARVIS_COLD_ROOT", isDirectory: true)
        try policy.validateUSBWrite(staging, volumeRoot: root); try policy.validateUSBWrite(vault, volumeRoot: root)
        if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        if FileManager.default.fileExists(atPath: vault.path) { throw CeremonyError.transactionFailed("USB already contains JARVIS_COLD_ROOT; use a fresh/empty drive") }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            try writeBlobAtomically0600(try certificate.jsonData(), to: staging.appendingPathComponent("birth_certificate.json"), errorContext: "USB birth certificate")
            try writeBlobAtomically0600(publicKey, to: staging.appendingPathComponent("cold_root_public.key"), errorContext: "USB cold root public key")
            try privateKeyWriter { bytes in
                try writeBlobAtomically0600(bytes, to: staging.appendingPathComponent("cold_root_private.key"), errorContext: "USB cold root private key")
            }
            try writeChunksAtomically0600(to: staging.appendingPathComponent("paper_backup_verification.txt"), errorContext: "USB paper backup verification") { writeChunk in
                try mnemonic.withPaperBackupBytes(ceremonyHash: ceremonyHash, writeChunk)
            }
            let identity = try Self.physicalIdentity(for: root)
            guard identity.identityID == device.id else {
                try audit.record("usb_identity_changed", outcome: "fail", metadata: ["expected": device.id, "actual": identity.identityID])
                throw CeremonyError.usbIdentityChanged(expected: device.id, actual: identity.identityID)
            }
            let usbCert = try Self.makeUSBDeviceCertificate(identity: identity, ceremonyID: ceremonyID, signer: usbCertificateSigner)
            try Self.verifyUSBDeviceCertificate(usbCert, expected: identity, publicKey: publicKey)
            try writeBlobAtomically0600(try usbCert.jsonData(), to: staging.appendingPathComponent(".jarvis_usb_cert"), errorContext: "USB device certificate")
            try FileManager.default.moveItem(at: staging, to: vault)
            return vault.appendingPathComponent("birth_certificate.json")
        } catch let error as CeremonyError {
            if case .usbIdentityChanged = error { throw error }
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            throw error
        } catch {
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
            throw error
        }
    }

    public func cleanupIncompleteCeremony(policy: PathPolicy) {
        let staging = device.volumeURL.appendingPathComponent(".jarvis_birth_staging", isDirectory: true)
        do {
            try policy.validateUSBWrite(staging, volumeRoot: device.volumeURL)
            if FileManager.default.fileExists(atPath: staging.path) { try FileManager.default.removeItem(at: staging) }
        } catch {
            fputs("JARVIS USB cleanup failed: \(error)\n", stderr)
        }
    }

    public static func makeUSBDeviceCertificate(identity: USBDevicePhysicalIdentity,
                                                ceremonyID: String,
                                                signer: (_ canonicalPayload: Data) throws -> Data) throws -> USBDeviceCertificate {
        var cert = USBDeviceCertificate(volumeUUID: identity.volumeUUID,
                                        bsdName: identity.bsdName,
                                        vendorString: identity.vendorString,
                                        modelString: identity.modelString,
                                        ceremonyID: ceremonyID,
                                        writeProtectState: identity.writeProtectState)
        cert = USBDeviceCertificate(volumeUUID: cert.volumeUUID,
                                    bsdName: cert.bsdName,
                                    vendorString: cert.vendorString,
                                    modelString: cert.modelString,
                                    ceremonyID: cert.ceremonyID,
                                    writeProtectState: cert.writeProtectState,
                                    createdAtUnix: cert.createdAtUnix,
                                    signatureHex: hex(try signer(cert.canonicalPayloadData)))
        return cert
    }

    public static func verifyUSBDeviceCertificate(_ cert: USBDeviceCertificate,
                                                  expected: USBDevicePhysicalIdentity,
                                                  publicKey: Data) throws {
        guard cert.volumeUUID == expected.volumeUUID,
              cert.bsdName == expected.bsdName,
              cert.vendorString == expected.vendorString,
              cert.modelString == expected.modelString,
              cert.writeProtectState == expected.writeProtectState else {
            throw CeremonyError.usbIdentityChanged(expected: expected.identityID, actual: "\(cert.volumeUUID)|\(cert.bsdName)")
        }
        guard let signature = unhex(cert.signatureHex), ColdRootKey.verify(signature: signature, message: cert.canonicalPayloadData, publicKey: publicKey) else {
            throw CeremonyError.verificationFailed
        }
    }

    public static func verifyUSBDeviceCertificate(at vaultRoot: URL, expected: USBDevicePhysicalIdentity, publicKey: Data) throws {
        let url = vaultRoot.appendingPathComponent(".jarvis_usb_cert")
        let certData = try Data(contentsOf: url)
        let cert = try decodeBoundedJSON(certData, as: USBDeviceCertificate.self, maxBytes: 64 * 1024, maxDepth: 4)
        try verifyUSBDeviceCertificate(cert, expected: expected, publicKey: publicKey)
    }

    public static func physicalIdentityID(for volumeURL: URL) throws -> String {
        try physicalIdentity(for: volumeURL).identityID
    }

    public static func physicalIdentity(for volumeURL: URL) throws -> USBDevicePhysicalIdentity {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { throw CeremonyError.transactionFailed("DiskArbitration session unavailable") }
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volumeURL as CFURL) else {
            throw CeremonyError.transactionFailed("DiskArbitration could not resolve volume path \(volumeURL.path)")
        }
        guard let description = DADiskCopyDescription(disk) as? [String: Any] else {
            throw CeremonyError.transactionFailed("DiskArbitration description unavailable for \(volumeURL.path)")
        }
        guard let uuid = description[kDADiskDescriptionVolumeUUIDKey as String] else {
            throw CeremonyError.transactionFailed("USB volume UUID unavailable for \(volumeURL.path)")
        }
        let uuidString: String
        if let uuidValue = uuid as? UUID {
            uuidString = uuidValue.uuidString
        } else if let uuidValue = uuid as? NSUUID {
            uuidString = uuidValue.uuidString
        } else {
            uuidString = String(describing: uuid)
        }
        guard let bsd = description[kDADiskDescriptionMediaBSDNameKey as String] as? String, !bsd.isEmpty else {
            throw CeremonyError.transactionFailed("USB BSD media name unavailable for \(volumeURL.path)")
        }
        let vendor = description[kDADiskDescriptionDeviceVendorKey as String].map { String(describing: $0) } ?? "unknown-vendor"
        let model = description[kDADiskDescriptionDeviceModelKey as String].map { String(describing: $0) } ?? "unknown-model"
        let writeProtectedValue = description[kDADiskDescriptionMediaWritableKey as String] as? Bool
        let writeProtect = writeProtectedValue == false ? "write_protected" : "writable"
        return USBDevicePhysicalIdentity(volumeUUID: uuidString, bsdName: bsd, vendorString: vendor, modelString: model, writeProtectState: writeProtect)
    }
}

public final class DiskArbitrationUSBMonitor: ObservableObject {
    @Published public private(set) var devices: [USBDevice] = []
    private var session: DASession?
    public init() { start(); rescanMountedVolumes() }
    deinit {
        if let session { DASessionUnscheduleFromRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) }
    }

    public func start() {
        guard session == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        session = s
        let context = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, diskChangedCallback, context)
        DARegisterDiskDisappearedCallback(s, nil, diskChangedCallback, context)
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
    }

    fileprivate func handleDiskTopologyChange() { rescanMountedVolumes() }

    public func rescanMountedVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey, .volumeIsRemovableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        devices = urls.compactMap { url in
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                guard values.volumeIsRemovable == true else { return nil }
                let id = try USBVaultWriter.physicalIdentityID(for: url)
                return USBDevice(id: id,
                                 volumeURL: url,
                                 displayName: values.volumeName ?? url.lastPathComponent,
                                 sizeBytes: UInt64(values.volumeTotalCapacity ?? 0),
                                 filesystem: values.volumeLocalizedFormatDescription ?? "unknown",
                                 wholeDiskIdentifier: nil)
            } catch {
                return nil
            }
        }
    }
}

private func diskChangedCallback(_ disk: DADisk, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<DiskArbitrationUSBMonitor>.fromOpaque(context).takeUnretainedValue()
    monitor.handleDiskTopologyChange()
}
