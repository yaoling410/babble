import Foundation
import SwiftUI

/// Baby profile stored in UserDefaults via @AppStorage.
final class BabyProfile: ObservableObject {
    @AppStorage("babyName") var babyName: String = ""
    @AppStorage("babyAgeMonths") var babyAgeMonths: Int = 0
    @AppStorage("backendURL") var backendURL: String = "http://localhost:8000"
}
