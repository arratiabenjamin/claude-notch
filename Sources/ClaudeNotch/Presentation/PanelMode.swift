// PanelMode.swift
// State machine for the floating panel's visual presentation.
//
//   .hidden          → panel ordered out, no chrome on screen.
//   .compact         → panel sits ON the notch (Dynamic Island style),
//                      showing only logo + counter.
//   .expanded        → panel hangs BELOW the notch, full session list.
//   .freeFloating    → legacy v1.x mode for non-notch displays. Pill in the
//                      user's preferred corner (top-right by default).
//
// The orchestrator (AppController) drives transitions between these.
enum PanelMode: Equatable {
    case hidden
    case compact
    case expanded
    case freeFloating
}
