import SwiftUI

@main
struct ClipTextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState.shared

    var body: some Scene {
        MenuBarExtra("ClipText", systemImage: "doc.on.clipboard") {
            if !appState.permissionsManager.hasScreenRecordingPermission || !appState.isAccessibilityTrusted {
                Menu {
                    if !appState.permissionsManager.hasScreenRecordingPermission {
                        Button("Enable Screen Recording") {
                            appState.openScreenRecordingSettings()
                        }
                    }
                    if !appState.isAccessibilityTrusted {
                        Button("Enable Accessibility for Automatic Paste") {
                            appState.openAccessibilitySettings()
                        }
                    }
                } label: {
                    Label("Action Needed", systemImage: "exclamationmark.triangle.fill")
                }

                Divider()
            }

            Button {
                appState.showPanel()
            } label: {
                Label("Clipboard History (\(appState.hotKey.displayString))", systemImage: "clock.arrow.circlepath")
            }

            Button {
                appState.startScreenOCR()
            } label: {
                Label("Extract Text from Screen… (\(appState.ocrHotKey.displayString))", systemImage: "text.viewfinder")
            }

            Button {
                appState.captureAndAnnotate()
            } label: {
                Label("Capture and Annotate…", systemImage: "camera.viewfinder")
            }

            if appState.isRecordingGIF {
                Button {
                    appState.finishGIFRecording()
                } label: {
                    Label("Stop GIF Recording", systemImage: "stop.circle.fill")
                }

                Button {
                    appState.cancelGIFRecording()
                } label: {
                    Label("Cancel GIF Recording", systemImage: "stop.circle")
                }
            } else {
                Button {
                    appState.recordGIF()
                } label: {
                    Label("Record GIF…", systemImage: "record.circle")
                }
            }

            Button {
                appState.saveLatestGIF()
            } label: {
                Label("Save Latest GIF…", systemImage: "square.and.arrow.down")
            }

            Divider()

            Button {
                appState.ignoreNextCopy()
            } label: {
                Label("Ignore Next Copy", systemImage: "eye.slash")
            }

            if appState.isHistoryPaused {
                Button {
                    appState.resumeHistory()
                } label: {
                    Label("Resume History", systemImage: "play.circle")
                }
            } else {
                Menu {
                    ForEach(ClipboardPauseDuration.allCases) { duration in
                        Button(duration.title) {
                            appState.pauseHistory(for: duration)
                        }
                    }
                } label: {
                    Label("Pause History", systemImage: "pause.circle")
                }
            }

            Divider()

            if appState.isCapturingStack {
                Button {
                    appState.finishClipboardStack()
                } label: {
                    Label("Finish Stack Capture (\(appState.clipboardStack.count))", systemImage: "checkmark.circle")
                }

                Button {
                    appState.cancelClipboardStack()
                } label: {
                    Label("Cancel Stack Capture", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    appState.startClipboardStack()
                } label: {
                    Label("Start Clipboard Stack", systemImage: "square.stack.3d.up")
                }
            }

            if !appState.isCapturingStack && !appState.clipboardStack.isEmpty {
                Button {
                    appState.pasteNextStackItem()
                } label: {
                    Label("Paste Next Stack Item", systemImage: "arrow.down.doc")
                }

                Button {
                    appState.clearClipboardStack()
                } label: {
                    Label("Clear Clipboard Stack", systemImage: "trash")
                }
            }

            Divider()

            Button {
                appState.showFavorites()
            } label: {
                Label("Library…", systemImage: "star")
            }

            Divider()

            Button {
                appState.showSettings()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }

            if appState.hasCustomPanelPosition {
                Button {
                    appState.resetPanelPosition()
                } label: {
                    Label("Reset Panel Position to Caret", systemImage: "arrow.counterclockwise")
                }
            }

            Divider()

            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        .menuBarExtraStyle(.menu)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}
