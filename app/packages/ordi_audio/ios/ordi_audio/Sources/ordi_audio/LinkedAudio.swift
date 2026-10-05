import AVFoundation
import CoreBluetooth

/// Bluetooth headsets the phone itself is connected to — the Audios are one —
/// and, where a headset offers it, its battery level.
///
/// A headset like the Audios is paired in iOS Settings and connected by iOS,
/// not by the app: an app cannot open that kind of connection, only see it.
/// Seeing it needs no permission. The battery is a different matter: iOS
/// keeps the level a headset reports over its audio link to itself, so the
/// only way to it is the standard Battery Service, if the headset has one.
/// Touch only from the main thread.
final class LinkedAudio: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private static let batteryService = CBUUID(string: "180F")
  private static let batteryLevel = CBUUID(string: "2A19")
  /// Services nearly every device has, used only to list what the phone is
  /// connected to when diagnosing a headset that shows no battery.
  private static let commonServices = [
    CBUUID(string: "180F"), CBUUID(string: "180A"), CBUUID(string: "1800"),
    CBUUID(string: "1801"),
  ]

  private var central: CBCentralManager?
  private var peripheral: CBPeripheral?
  private var characteristic: CBCharacteristic?
  private var level = -1
  private var linkedNames: [String] = []

  /// Names of the Bluetooth audio devices connected right now.
  static func names() -> [String] {
    let session = AVAudioSession.sharedInstance()
    let bluetooth: Set<AVAudioSession.Port> = [.bluetoothHFP, .bluetoothA2DP, .bluetoothLE]
    let ports =
      session.currentRoute.outputs + session.currentRoute.inputs
      + (session.availableInputs ?? [])
    var seen: [String] = []
    for port in ports where bluetooth.contains(port.portType) && !seen.contains(port.portName) {
      seen.append(port.portName)
    }
    return seen
  }

  /// What is connected, and the battery of the headset called `wanted` if it
  /// is one of them and reports one. -1 when there is no level to show.
  func snapshot(batteryFor wanted: String?) -> [String: Any] {
    let names = Self.names()
    if let wanted, names.contains(where: { Self.same($0, wanted) }) {
      refreshBattery(for: wanted)
    } else {
      drop()
    }
    return ["names": names, "battery": level, "gatt": linkedNames]
  }

  private static func same(_ a: String, _ b: String) -> Bool {
    let x = a.lowercased(), y = b.lowercased()
    return x == y || x.contains(y) || y.contains(x)
  }

  private func refreshBattery(for wanted: String) {
    guard let central else {
      // Its state arrives a moment later; the next snapshot carries on.
      central = CBCentralManager(
        delegate: self, queue: .main,
        options: [CBCentralManagerOptionShowPowerAlertKey: false])
      return
    }
    guard central.state == .poweredOn else { return }

    if let peripheral, peripheral.state == .connected {
      if let characteristic { peripheral.readValue(for: characteristic) }
      return
    }
    if let peripheral, peripheral.state == .connecting { return }

    linkedNames = central.retrieveConnectedPeripherals(withServices: Self.commonServices)
      .map { $0.name ?? "?" }
    let withBattery = central.retrieveConnectedPeripherals(withServices: [Self.batteryService])
    guard let match = withBattery.first(where: { Self.same($0.name ?? "", wanted) }) else {
      return
    }
    peripheral = match
    match.delegate = self
    central.connect(match)
  }

  private func drop() {
    if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
    peripheral = nil
    characteristic = nil
    level = -1
  }

  // MARK: - CBCentralManagerDelegate

  func centralManagerDidUpdateState(_ central: CBCentralManager) {}

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    peripheral.discoverServices([Self.batteryService])
  }

  func centralManager(
    _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
  ) {
    if peripheral == self.peripheral { drop() }
  }

  func centralManager(
    _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
  ) {
    if peripheral == self.peripheral { drop() }
  }

  // MARK: - CBPeripheralDelegate

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    for service in peripheral.services ?? [] where service.uuid == Self.batteryService {
      peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
  ) {
    for found in service.characteristics ?? [] where found.uuid == Self.batteryLevel {
      characteristic = found
      peripheral.readValue(for: found)
      if found.properties.contains(.notify) { peripheral.setNotifyValue(true, for: found) }
    }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
  ) {
    guard characteristic.uuid == Self.batteryLevel, let value = characteristic.value?.first
    else { return }
    level = min(max(Int(value), 0), 100)
  }
}
