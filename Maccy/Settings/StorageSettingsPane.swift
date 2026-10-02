import AppKit
import UniformTypeIdentifiers
import SwiftUI
import Defaults
import Settings

struct StorageSettingsPane: View {
  @Observable
  class ViewModel {
    var saveFiles = false {
      didSet {
        Defaults.withoutPropagation {
          if saveFiles {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.files.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.files.types)
          }
        }
      }
    }

    var saveImages = false {
      didSet {
        Defaults.withoutPropagation {
          if saveImages {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.images.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.images.types)
          }
        }
      }
    }

    var saveText = false {
      didSet {
        Defaults.withoutPropagation {
          if saveText {
            Defaults[.enabledPasteboardTypes].formUnion(StorageType.text.types)
          } else {
            Defaults[.enabledPasteboardTypes].subtract(StorageType.text.types)
          }
        }
      }
    }

    private var observer: Defaults.Observation?

    init() {
      observer = Defaults.observe(.enabledPasteboardTypes) { change in
        self.saveFiles = change.newValue.isSuperset(of: StorageType.files.types)
        self.saveImages = change.newValue.isSuperset(of: StorageType.images.types)
        self.saveText = change.newValue.isSuperset(of: StorageType.text.types)
      }
    }

    deinit {
      observer?.invalidate()
    }
  }

  @Default(.size) private var size
  @Default(.retentionMonths) private var retentionMonths
  @Default(.sortBy) private var sortBy

  @State private var viewModel = ViewModel()
  @State private var storageSize = Storage.shared.size
  @State private var transferMessage: String?
  @State private var isTransferring = false

  private let sizeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.minimum = 1
    formatter.maximum = 999
    return formatter
  }()

  var body: some View {
    Settings.Container(contentWidth: 450) {
      Settings.Section(
        bottomDivider: true,
        label: { Text("Save", tableName: "StorageSettings") }
      ) {
        Toggle(
          isOn: $viewModel.saveFiles,
          label: { Text("Files", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveImages,
          label: { Text("Images", tableName: "StorageSettings") }
        )
        Toggle(
          isOn: $viewModel.saveText,
          label: { Text("Text", tableName: "StorageSettings") }
        )
        Text("SaveDescription", tableName: "StorageSettings")
          .controlSize(.small)
          .foregroundStyle(.gray)
      }

      Settings.Section(label: { Text("Size", tableName: "StorageSettings") }) {
        HStack {
          TextField("", value: $size, formatter: sizeFormatter)
            .frame(width: 80)
            .help(Text("SizeTooltip", tableName: "StorageSettings"))
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          Stepper("", value: $size, in: 1...999)
            .labelsHidden()
            .accessibilityLabel(Text("Size", tableName: "StorageSettings"))
          Text(storageSize)
            .controlSize(.small)
            .foregroundStyle(.gray)
            .help(Text("CurrentSizeTooltip", tableName: "StorageSettings"))
            .onAppear {
              storageSize = Storage.shared.size
            }
        }
      }

      Settings.Section(label: { Text("Retention", tableName: "StorageSettings") }) {
        Stepper(value: $retentionMonths, in: 1...24) {
          Text(String(format: NSLocalizedString("RetentionMonths", tableName: "StorageSettings", comment: ""), retentionMonths))
        }
      }

      Settings.Section(label: { Text("Transfer", tableName: "StorageSettings") }) {
        HStack {
          Button { exportHistory() } label: { Text("ExportHistory", tableName: "StorageSettings") }
          Button { restoreHistory() } label: { Text("RestoreHistory", tableName: "StorageSettings") }
        }
        .disabled(isTransferring)
        Text("TransferDescription", tableName: "StorageSettings")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Settings.Section(label: { Text("SortBy", tableName: "StorageSettings") }) {
        Picker("", selection: $sortBy) {
          ForEach(Sorter.By.allCases) { mode in
            Text(mode.description)
          }
        }
        .labelsHidden()
        .frame(width: 160, alignment: .leading)
        .help(Text("SortByTooltip", tableName: "StorageSettings"))
        .accessibilityLabel(Text("SortBy", tableName: "StorageSettings"))
      }
    }
    .alert("History transfer", isPresented: Binding(
      get: { transferMessage != nil },
      set: { if !$0 { transferMessage = nil } }
    )) {
      Button("OK") { transferMessage = nil }
    } message: {
      Text(transferMessage ?? "")
    }
  }

  private func exportHistory() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "Maccy-History-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
    panel.canCreateDirectories = true
    isTransferring = true
    panel.begin { response in
      defer { isTransferring = false }
      guard response == .OK, let url = panel.url else { return }
      do {
        let data = try Storage.shared.exportHistory()
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        transferMessage = "History exported to \(url.lastPathComponent)."
      } catch {
        transferMessage = error.localizedDescription
      }
    }
  }

  private func restoreHistory() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    isTransferring = true
    panel.begin { response in
      guard response == .OK, let url = panel.url else { isTransferring = false; return }
      Task { @MainActor in
        defer { isTransferring = false }
        do {
          let result = try Storage.shared.restoreHistory(Data(contentsOf: url))
          try await History.shared.load()
          storageSize = Storage.shared.size
          transferMessage = "Restored \(result.imported) clips; merged \(result.duplicates) duplicates. Skipped \(result.expired) clips outside the current retention period. Adjusted \(result.reassignedPins) pin shortcuts."
        } catch {
          transferMessage = error.localizedDescription
        }
      }
    }
  }
}

#Preview {
  StorageSettingsPane()
    .environment(\.locale, .init(identifier: "en"))
}
