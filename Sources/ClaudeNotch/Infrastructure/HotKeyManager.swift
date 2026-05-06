// HotKeyManager.swift
// Thin Swift wrapper around Carbon's RegisterEventHotKey for global hotkeys.
//
// Why Carbon (and not NSEvent.addGlobalMonitorForEvents)?
//   - Global monitors can OBSERVE key presses anywhere, but they can't
//     PREVENT another app (or the system) from seeing the same press.
//   - Carbon's RegisterEventHotKey captures the press exclusively, so
//     ⌥⌘Space toggles Claude Notch and never leaks into whichever app
//     the user happens to have focused.
//
// Concurrency:
//   The class itself is @MainActor — register/unregister and the user
//   handler all run on main. The Carbon C callback is nonisolated (it
//   has to be, it's a C function pointer) and does nothing but hop
//   back onto MainActor via `fire()` to invoke the stored handler.
import AppKit
import Carbon.HIToolbox

@MainActor
final class HotKeyManager {
    typealias Handler = @MainActor () -> Void

    /// Carbon refs need to live across the lifetime of the manager. Marked
    /// nonisolated(unsafe) so the C callback can access through Unmanaged
    /// without Sendable warnings — these pointers are only mutated from
    /// MainActor (register/unregister), and only READ from the C callback,
    /// which doesn't dereference them, so the unsafety here is fine.
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var eventHandler: EventHandlerRef?

    private var handler: Handler?

    /// Bytes 'CNO1' — used as the Carbon hotkey signature so we can tell
    /// our hotkey apart from anyone else's in a shared event handler.
    private let signature: UInt32 = 0x434E_4F31

    deinit {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        if let h = eventHandler { RemoveEventHandler(h) }
    }

    /// Register a global hotkey.
    /// - Parameter keyCode: a `kVK_*` virtual key code (e.g. `kVK_Space` = 49).
    /// - Parameter modifiers: Carbon flag mask (e.g. `cmdKey | optionKey`).
    /// - Returns: true if Carbon accepted the registration. Returns false if
    ///   the combo is already claimed system-wide; the caller should log and
    ///   keep going (the menu-bar item still works as a fallback).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping Handler) -> Bool {
        self.handler = handler

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyCarbonCallback,
            1,
            &spec,
            userData,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let id = EventHotKeyID(signature: signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    /// Called by the Carbon C callback. Hops onto main actor and runs the
    /// stored handler. Nonisolated so the callback can invoke it.
    nonisolated func fire() {
        Task { @MainActor in self.handler?() }
    }
}

/// Free-standing C-compatible function used as the EventHandlerProcPtr.
private func hotKeyCarbonCallback(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let mgr = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    mgr.fire()
    return noErr
}
