import CoreMIDI
import Foundation

/// Un appareil MIDI vu par l'iPad.
struct MIDIDevice: Identifiable, Hashable {
    enum Transport: String {
        case usb = "USB"
        case bluetooth = "Bluetooth"
        case network = "Réseau"
        case other = "Autre"

        var symbol: String {
            switch self {
            case .usb: return "cable.connector"
            case .bluetooth: return "dot.radiowaves.left.and.right"
            case .network: return "network"
            case .other: return "pianokeys"
            }
        }
    }

    let id: Int32          // identifiant unique CoreMIDI, stable d'un branchement à l'autre
    let name: String
    let manufacturer: String?
    let transport: Transport
}

/// Gère les claviers MIDI : USB (class-compliant), Bluetooth déjà appairé, réseau.
/// Détecte le branchement et le débranchement à chaud.
final class MIDIInput {
    var onNoteOn: ((Int, Int) -> Void)?
    var onNoteOff: ((Int) -> Void)?
    var onSustain: ((Bool) -> Void)?
    var onActivity: ((Int32) -> Void)?
    var onDevicesChanged: ((_ all: [MIDIDevice], _ added: [MIDIDevice], _ removed: [MIDIDevice]) -> Void)?
    private(set) var errorMessage: String?

    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var connected: [MIDIEndpointRef] = []
    private var known: [MIDIDevice] = []
    private var started = false
    private let lock = NSLock()
    private var disabled: Set<Int32> = []

    private enum Event {
        case on(Int, Int)
        case off(Int)
        case sustain(Bool)
    }

    func start() {
        guard !started else { return }
        started = true
        let clientStatus = MIDIClientCreateWithBlock("Clavier Futé" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged {
                DispatchQueue.main.async { self?.refresh() }
            }
        }
        guard clientStatus == noErr else {
            errorMessage = "Le service MIDI de l'iPad ne répond pas (code \(clientStatus))."
            return
        }
        let portStatus = MIDIInputPortCreateWithProtocol(client, "Entrée" as CFString, ._1_0, &port) { [weak self] list, refCon in
            let uid = Int32(truncatingIfNeeded: Int(bitPattern: refCon))
            self?.handle(list, from: uid)
        }
        guard portStatus == noErr else {
            errorMessage = "Impossible d'ouvrir l'entrée MIDI (code \(portStatus))."
            return
        }
        refresh(initial: true)
    }

    /// Choisit les claviers dont on ignore les notes.
    func setDisabled(_ ids: Set<Int32>) {
        lock.lock()
        disabled = ids
        lock.unlock()
    }

    /// Relit la liste des sources et s'y reconnecte. Appelé à chaque branchement.
    func refresh(initial: Bool = false) {
        guard started, port != 0 else { return }
        for source in connected { MIDIPortDisconnectSource(port, source) }
        connected.removeAll()

        var devices: [MIDIDevice] = []
        for i in 0..<MIDIGetNumberOfSources() {
            let source = MIDIGetSource(i)
            guard source != 0 else { continue }
            if intProperty(source, kMIDIPropertyOffline) == 1 { continue }
            let uid = intProperty(source, kMIDIPropertyUniqueID) ?? Int32(i + 1)
            let device = MIDIDevice(
                id: uid,
                name: stringProperty(source, kMIDIPropertyDisplayName) ?? "Clavier MIDI",
                manufacturer: stringProperty(source, kMIDIPropertyManufacturer),
                transport: transport(of: source)
            )
            devices.append(device)
            MIDIPortConnectSource(port, source, UnsafeMutableRawPointer(bitPattern: Int(uid)))
            connected.append(source)
        }

        let added = initial ? [] : devices.filter { d in !known.contains { $0.id == d.id } }
        let removed = known.filter { k in !devices.contains { $0.id == k.id } }
        known = devices
        onDevicesChanged?(devices, added, removed)
    }

    // MARK: Propriétés CoreMIDI

    private func intProperty(_ object: MIDIObjectRef, _ property: CFString) -> Int32? {
        var value: Int32 = 0
        return MIDIObjectGetIntegerProperty(object, property, &value) == noErr ? value : nil
    }

    private func stringProperty(_ object: MIDIObjectRef, _ property: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, property, &value) == noErr, let string = value?.takeRetainedValue() else {
            return nil
        }
        return string as String
    }

    private func transport(of source: MIDIEndpointRef) -> MIDIDevice.Transport {
        var entity = MIDIEntityRef()
        var device = MIDIDeviceRef()
        guard MIDIEndpointGetEntity(source, &entity) == noErr, entity != 0,
              MIDIEntityGetDevice(entity, &device) == noErr, device != 0 else { return .other }
        let owner = stringProperty(device, kMIDIPropertyDriverOwner) ?? ""
        if owner.contains("USB") { return .usb }
        if owner.contains("Bluetooth") { return .bluetooth }
        if owner.contains("RTP") || owner.contains("Network") { return .network }
        return .other
    }

    // MARK: Réception

    private func handle(_ list: UnsafePointer<MIDIEventList>, from uid: Int32) {
        lock.lock()
        let ignored = disabled.contains(uid)
        lock.unlock()
        if ignored { return }

        var events: [Event] = []
        for packet in list.unsafeSequence() {
            let wordCount = Int(packet.pointee.wordCount)
            withUnsafePointer(to: packet.pointee.words) { tuple in
                tuple.withMemoryRebound(to: UInt32.self, capacity: 64) { words in
                    var i = 0
                    while i < wordCount {
                        let word = words[i]
                        let type = word >> 28
                        if type == 0x2 { // message MIDI 1.0 de canal
                            let status = (word >> 16) & 0xF0
                            let data1 = Int((word >> 8) & 0x7F)
                            let data2 = Int(word & 0x7F)
                            switch status {
                            case 0x90: events.append(data2 > 0 ? .on(data1, data2) : .off(data1))
                            case 0x80: events.append(.off(data1))
                            case 0xB0 where data1 == 64: events.append(.sustain(data2 >= 64))
                            case 0xB0 where data1 == 123 || data1 == 120: events.append(.sustain(false))
                            default: break
                            }
                        }
                        switch type {
                        case 0x3, 0x4: i += 2
                        case 0x5: i += 4
                        default: i += 1
                        }
                    }
                }
            }
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onActivity?(uid)
            for event in events {
                switch event {
                case .on(let note, let velocity): self.onNoteOn?(note, velocity)
                case .off(let note): self.onNoteOff?(note)
                case .sustain(let down): self.onSustain?(down)
                }
            }
        }
    }
}
