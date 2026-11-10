import Observation
import StaveCore

/// The one Arc import in progress: its flow and where it reads from. "Choose Another File…" swaps both inside the same session, so the
/// sheet that shows it stays up. Holds no rules; the sheet's content is `ArcImportSheetContent`.
@MainActor @Observable
final class ArcImportSession: Identifiable {
    private(set) var flow: ArcImportFlow
    private(set) var source: ArcImportFlow.Source

    init(flow: ArcImportFlow, source: ArcImportFlow.Source) {
        self.flow = flow
        self.source = source
    }

    func replace(flow: ArcImportFlow, source: ArcImportFlow.Source) {
        self.flow = flow
        self.source = source
    }
}

/// What the first-run sheet needs besides the shared settings: whether Arc's file is there to offer.
struct FirstRunRequest: Identifiable {
    let id = 0
    let offersArcImport: Bool
}

/// The modal sheet a browser window shows, if any. One at a time, so the first-run sheet hands over to the import sheet cleanly.
enum WindowSheet: Identifiable {
    case firstRun(FirstRunRequest)
    case arcImport(ArcImportSession)

    var id: String {
        switch self {
        case .firstRun: "firstRun"
        case .arcImport(let session): "arcImport-\(ObjectIdentifier(session).hashValue)"
        }
    }
}
