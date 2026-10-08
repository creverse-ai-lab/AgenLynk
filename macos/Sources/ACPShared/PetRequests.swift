import Foundation

/// What the Pet asks of AgenLynk. The Pet only renders; it holds no tokens and
/// talks to no monitor, so a click is handed over as a distributed
/// notification carrying the clicked node's id and nothing else.
public enum PetRequest {
    /// Bring the Frontdoor's window forward, as the notch card does.
    /// userInfo: ["id": the pet-state agent id of the Frontdoor].
    public static let openFrontdoor = Notification.Name("ai.creverse.agenlynk.pet.openFrontdoor")
}
