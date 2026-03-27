import Foundation

enum AgeDefaults {
    static func bottleOz(ageMonths: Int) -> Double {
        switch ageMonths {
        case 0...1: return 2.5
        case 2...3: return 4
        case 4...6: return 5
        case 7...9: return 6
        case 10...12: return 6
        case 13...18: return 5
        default: return 5
        }
    }

    static func breastMinutes(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 25
        case 2...3: return 20
        case 4...6: return 17
        case 7...9: return 15
        case 10...12: return 14
        case 13...18: return 12
        default: return 12
        }
    }

    static func napMinutes(ageMonths: Int) -> Int {
        switch ageMonths {
        case 0...1: return 45
        case 2...3: return 60
        case 4...6: return 75
        case 7...9: return 90
        case 10...12: return 90
        case 13...18: return 105
        default: return 120
        }
    }

    static func solidsOz(ageMonths: Int) -> Double? {
        switch ageMonths {
        case 6...8: return 1
        case 9...11: return 2
        case 12...17: return 3
        case 18...24: return 4
        default: return nil
        }
    }


    // MARK: - Auto-completion timeouts (used by OnDevicePipeline)

    static func autoCompleteTimeoutMinutes(eventType: String, subtype: String?) -> Int {
        switch eventType {
        case "sleep":    return 180  // 3 hours
        case "feeding":
            switch subtype {
            case "breast":  return 45
            case "bottle":  return 30
            case "solids":  return 30
            case "pumping": return 30
            default:        return 45
            }
        case "activity": return 60
        default:         return 120  // 2 hours
        }
    }

    // MARK: - Amount adjustment

    static func adjusted(_ value: Double, descriptor: AmountDescriptor) -> Double {
        let factor: Double
        switch descriptor {
        case .concrete:  return value
        case .vague:     return value
        case .small:     factor = 0.7
        case .large:     factor = 1.3
        }
        return (factor * value).rounded(.up)
    }

    enum AmountDescriptor: String, Codable {
        case concrete   // "4 oz" — caregiver gave a number
        case vague      // "had a bottle" — no amount
        case small      // "a little", "small feed"
        case large      // "a lot", "big feed"
    }
}
