import AppKit

extension NSLayoutConstraint {
    func withPriority(_ priority: Priority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
