import AppKit

class PrefWindow: NSWindow {
	override func keyDown(with event: NSEvent) {
		if event.modifierFlags.rawValue & 0x100000 == 1048576 { // ⌘ key
			guard let del = NSApp.delegate as? AppDelegate else { return }
			
			switch event.characters {
				case "w": del.closePrefs()
				case "q": del.quitClicked(NSMenuItem())
				default: break
			}
		}
		
		super.keyDown(with: event)
	}
}
