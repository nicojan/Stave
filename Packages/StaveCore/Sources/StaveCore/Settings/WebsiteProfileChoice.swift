import Foundation

/// Which profile Settings ▸ Websites shows (R1-BH6): the one the user picked, else the front browser window's, else the first.
public enum WebsiteProfileChoice {
    public static func shown(chosen: UUID?, front: UUID?, in profiles: [Profile]) -> UUID? {
        for candidate in [chosen, front] {
            if let candidate, profiles.contains(where: { $0.id == candidate }) { return candidate }
        }
        return profiles.first?.id
    }
}
