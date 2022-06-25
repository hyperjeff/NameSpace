import Carbon
import Cocoa

typealias KeyInfo = (keycode: Int, enabled: Bool, flags: [Bool])

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
	 
	@IBOutlet weak var menu: NSMenu!
	@IBOutlet weak var preferenceWindow: PrefWindow!
	@IBOutlet weak var table: NSTableView!
	@IBOutlet weak var includeCustomFoldersButton: NSButton!
	@IBOutlet weak var openSpaceFolderMenuItem: NSMenuItem!
	
	let workspace = NSWorkspace.shared
	let defaults = UserDefaults.standard
	let fileman = FileManager.default
	var spaceNames: [String] = []
	var movingRows = false
	let spaceNameKey = "Space Names"
	let mainDisplay = "Main"
	let spacesMonitorFile = "com.apple.spaces"
	let keycodeFile = "com.apple.symbolichotkeys"
	let statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	let connection = _CGSDefaultConnection()
	var directionsToMissionControl = ""
	var directionsToKeyboardControl = ""
	var spaceRequest: Int?
	var usesCustomFolders: Bool = false
	let usesCustomFoldersKey = "UsesCustomFolders"
	var currentSpaceName: String?
	
	func applicationWillFinishLaunching(_ notification: Notification) {
		NSApplication.shared.setActivationPolicy(.accessory)
		
		mainApp = self
		
		setupAppHotkey()
		
		if let names = defaults.value(forKey: spaceNameKey) as? [String] {
			spaceNames = names
		}
		
		workspace.notificationCenter.addObserver(self,
			selector: #selector(updateActiveSpaceNumber),
			name: NSWorkspace.activeSpaceDidChangeNotification,
			object: workspace
		)
		
		func directions(steps: [String]) -> String {
			"\n\n" + steps.joined(separator: "\n↓\n") + "\n\n"
		}
		
		if #available(macOS 13.0, *) {
			directionsToMissionControl = directions(steps: ["Settings", "Desktop & Dock", "Mission Control"])
			directionsToKeyboardControl = directions(steps: ["Settings", "Keyboard", "Keyboard Shortcuts", "Mission Control"])
		}
		else {
			directionsToMissionControl = directions(steps: ["Settings", "Mission Control"])
			directionsToKeyboardControl = directions(steps: ["Settings", "Keyboard", "Shortcuts", "Mission Control"])
		}
		
		table.registerForDraggedTypes([.string])
				
		statusBarItem.menu = menu
		preferenceWindow.center()
		
		configureSpaceMonitor()
		updateActiveSpaceNumber()
		readKeycodeMap()
		
		let usf = defaults.bool(forKey: usesCustomFoldersKey)
		includeCustomFoldersButton.state = (usf ? .on : .off)
		
		openSpaceFolderMenuItem.isHidden = !usf
		
		for (index, name) in spaceNames.enumerated() {
			menu.insertItem(withTitle: menuTitle(row: index, name: name), action: #selector(spacePicked), keyEquivalent: "", at: index)
		}
		
	}
	
	func setupAppHotkey() {
		let keycodes = [123, 124, 125] // ← → ↓
		
		for sigIndex in 0...2 {
			let hotkeyID = EventHotKeyID(signature: eventHotKeySignature + UInt32(sigIndex), id: UInt32(sigIndex + 1))
			var hotkeyReference: EventHotKeyRef?
			
			// +cmdKey
			let error = RegisterEventHotKey(UInt32(keycodes[sigIndex]), UInt32(controlKey+optionKey), hotkeyID, GetApplicationEventTarget(), 0, &hotkeyReference)
			
			if error != noErr || hotkeyReference == nil {
				return
			}
		}
		
		let eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
		InstallEventHandler(GetEventDispatcherTarget(), hotkeyHandler, 1, [eventSpec], nil, nil)
	}
	
	func menuTitle(row: Int, name: String) -> String {
		var disabled = true
		
		if keycodeMap.keys.contains(row),
		   let map = keycodeMap[row] {
			disabled = !map.enabled
		}
		
		let pad = (row < 9) ? " " : ""
		return "\(pad)\(row + 1).\t\(name)\(disabled ? "   ⚠️" : "")"
	}
	
	func updateMenuItem(_ row: Int, withName name: String) {
		menu.item(at: row)?.title = menuTitle(row: row, name: name)
	}
	
	func saveSpaceNames() {
		defaults.set(spaceNames, forKey: spaceNameKey)
		defaults.synchronize()
	}
	
	func updateMenuItems() {
		for (index, name) in spaceNames.enumerated() {
			updateMenuItem(index, withName: name)
		}
	}
	
	func plistPreferenceURL(for name: String) -> URL {
		fileman.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/" + name + ".plist")
	}
	
	func checkBoxForSetting(name: String) -> String {
		if #available(macOS 13.0, *) {
			return "\(name)  ▢"
		} else {
			return "▢ \(name)"
		}
	}
	
	func configureSpaceMonitor() {
		let spacesURL = plistPreferenceURL(for: spacesMonitorFile)
		let fileDescriptor = open(spacesURL.path, O_EVTONLY)
		
		if fileman.fileExists(atPath: spacesURL.path),
		   let main = NSDictionary(contentsOf: spacesURL),
		   let spansDisplaysInt = main["spans-displays"] as? Int,
		   let config = main["SpacesDisplayConfiguration"] as? NSDictionary,
		   let data = config["Management Data"] as? NSDictionary,
		   let modeInt = data["Management Mode"] as? Int
		{
			let spansDisplays = (spansDisplaysInt == 1)
			let autoArrangeSpaces = (modeInt == 1)
			
			if autoArrangeSpaces {
				alertAboutPrefs(title: "Configuration Issue", detailedMessage: "Spaces must be set to not auto-rearrange in order for this to work. Head to" + directionsToMissionControl + checkBoxForSetting(name: "Auto rearrange Spaces"))
				
				NSApplication.shared.terminate(self)
			}
			
			if !spansDisplays && 1 < NSScreen.screens.count {
				alertAboutPrefs(title: "Possible Config Issue", detailedMessage: "When using more than one display, unset separate Spaces for displays." + directionsToMissionControl + checkBoxForSetting(name: "Displays have separate Spaces"))
			}
		}
		
		if fileDescriptor == -1 {
			let alert = NSAlert()
			alert.messageText = "Unable to open file:\n\(spacesMonitorFile)"
			alert.alertStyle = .critical
			alert.addButton(withTitle: "OK")
			alert.runModal()
			
			NSApplication.shared.terminate(self)
		}
		
		let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fileDescriptor, eventMask: .all, queue: .main)
		
		source.setEventHandler { () -> Void in
			if (source.data.rawValue & DispatchSource.FileSystemEvent.delete.rawValue != 0) {
				source.cancel()
				self.updateActiveSpaceNumber()
				self.configureSpaceMonitor()
			}
		}
		
		source.setCancelHandler { () -> Void in
			close(fileDescriptor)
		}
		
		source.activate()
	}
	
	func readKeycodeMap() {
		let symbolicLookup = plistPreferenceURL(for: keycodeFile)
		
		if fileman.fileExists(atPath: symbolicLookup.path),
		   let main = NSDictionary(contentsOf: symbolicLookup),
		   let dict = main["AppleSymbolicHotKeys"] as? NSDictionary {
			
			for spaceNumber in 0...15 {
				if let subDict = dict.object(forKey: "\(spaceNumber + 118)") as? NSDictionary,
				   let enabled = subDict["enabled"] as? Bool,
				   let params = (subDict["value"] as? AnyObject)?["parameters"],
				   let paramSet = (params as? [AnyObject]),
				   let key = paramSet[1] as? Int,
				   let mode = paramSet[2] as? Int {
					
					let command = ((mode & 0x100000) == 0) ? false : true
					let alt	    = ((mode & 0x080000) == 0) ? false : true
					let control = ((mode & 0x040000) == 0) ? false : true
					let shift   = ((mode & 0x020000) == 0) ? false : true
					
					keycodeMap[spaceNumber] = (key, enabled, [shift, control, alt, command])
				}
			}
		}
		
//		log(keycodeMap.keys.sorted().map { "\($0): \(keycodeMap[$0]!.keycode)" }.joined(separator: "\n"))
	}
	
	func openSystemPreferences() {
		// TODO: I cannot figure out a way to get this to take the user straight to keyboard prefs. grrrr.
		
		if let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.symbolichotkeys") {
			workspace.open(keyboardSettingsURL)
		}
	}
	
	func alertAboutPrefs(title: String, detailedMessage: String) {
		let alert = NSAlert()
		alert.messageText = title
		alert.addButton(withTitle: "OK")
		alert.addButton(withTitle: "Cancel")
		alert.alertStyle = .warning
		
		let paragraph = NSMutableParagraphStyle()
		paragraph.alignment = .center
		
		var textColor: NSColor = .white
		if #available(macOS 10.13, *) {
			textColor = NSColor(named: NSColor.Name("AlertText"))!
		}
		
		let accessory = NSTextView(frame: CGRect(x: 0, y: 0, width: 250, height: 250))
		let attributes : [NSAttributedString.Key: Any] = [
			.font : NSFont.systemFont(ofSize: 16),
			.paragraphStyle : paragraph,
			.foregroundColor : textColor,
		]
		
		let accessoryAttributedText = NSAttributedString(string: detailedMessage, attributes: attributes)
		
		accessory.textStorage!.setAttributedString(accessoryAttributedText)
		accessory.isEditable = false
		accessory.drawsBackground = false
		alert.accessoryView = accessory
		
		if alert.runModal() == .alertFirstButtonReturn {
			openSystemPreferences()
		}
	}
	
	func closePrefs() {
		preferenceWindow.close()
	}
	
	func openMenu() {
		if let window = statusBarItem.button?.window {
			let position = CGPoint(x: window.frame.origin.x, y: window.frame.origin.y - 7)
			menu.popUp(positioning: nil, at: position, in: nil)
		}
	}
	
	func goToSpace(atIndex index: Int, activateFirst: Bool = false) {
		var canGoToSpace = false
		
		if keycodeMap.keys.contains(index),
		   let keymap = keycodeMap[index] {
			
			if keymap.enabled {
				canGoToSpace = true
				
				headToSpace(keymap: keymap)
			}
		}
		
		if !canGoToSpace {
			alertAboutPrefs(title: "Couldn't Go to Space!", detailedMessage: "Space \(index + 1) has no shortcut. Assign one now by going to:" + directionsToKeyboardControl + "Pick a unique key combo and make sure that it's enabled.")
		}
	}
	
	// MARK: - Callbacks -
	
	@objc func spacePicked(item: NSMenuItem) {
		if let index = menu.items.firstIndex(of: item) {
			goToSpace(atIndex: index)
		}
	}
	
	@objc func updateActiveSpaceNumber() {
		let displays = CGSCopyManagedDisplaySpaces(connection) as! [NSDictionary]
		let activeDisplay = CGSCopyActiveMenuBarDisplayIdentifier(connection) as! String
		let allSpaces: NSMutableArray = []
		var activeSpaceID: Int?
		
		for display in displays {
			if let current = display["Current Space"] as? [String : Any],
			   let spaces = display["Spaces"] as? [[String : Any]],
			   let displayID = display["Display Identifier"] as? String {
				
				if [mainDisplay, activeDisplay].contains(displayID),
				   let managedSpaceID = current["ManagedSpaceID"] as? Int {
					activeSpaceID = managedSpaceID
				}
				
				spaces
					.filter { $0["TileLayoutManager"] as? [String : Any] == nil }
					.forEach { allSpaces.add($0) }
			}
		}
		
		guard let activeSpaceID = activeSpaceID else { return }
		
		if spaceNames.count != allSpaces.count {
			if spaceNames.count < allSpaces.count {
				while spaceNames.count != allSpaces.count {
					let index = spaceNames.count
					let name = "Desktop \(index + 1)"
					
					spaceNames.append(name)
					menu.insertItem(withTitle: menuTitle(row: index, name: name), action: #selector(spacePicked), keyEquivalent: "", at: index)
				}
			}
			else {
				for index in (allSpaces.count ..< spaceNames.count).reversed() {
					spaceNames.removeLast()
					menu.removeItem(at: index)
				}
			}
			
			saveSpaceNames()
			table.reloadData()
		}
		
		for (index, space) in allSpaces.enumerated() {
			let spaceID = (space as! NSDictionary)["ManagedSpaceID"] as! Int
			
			if spaceID == activeSpaceID {
				if spaceStack.isEmpty {
					spaceStack.append(index)
					spaceStackIndex = 0
				}
				else {
					if spaceStackIndex == (spaceStack.count - 1),
					   let last = spaceStack.last,
					   last != index {
						spaceStack.append(index)
						spaceStackIndex = spaceStack.count - 1
					}
					else if spaceStack[spaceStackIndex] != index {
						spaceStack.removeLast(spaceStack.count - spaceStackIndex - 1)
						spaceStack.append(index)
						spaceStackIndex = spaceStack.count - 1
					}
				}
				
				let s = "①".unicodeScalars
				let v = s[s.startIndex].value
				
				log("spaceStack: [" + spaceStack.enumerated()
					.map({ (i, x) in i == spaceStackIndex ?
						(Int(x) == 0 ? "⓪" : String(UnicodeScalar(v + UInt32(x) - 1)!)) :
						"\(x)"
					})
					.joined(separator: ", ") + "]")
				
				currentSpaceName = spaceNames[index]
				
				DispatchQueue.main.async {
					self.statusBarItem.button?.title = String("\(self.spaceNames[index])")
				}
				
				return
			}
		}
	}
	
	// MARK: - UI Actions -
	
	@IBAction func updateCustomFolders(_ sender: NSButton) {
		usesCustomFolders = (sender.state == .on)
		defaults.setValue(usesCustomFolders, forKey: usesCustomFoldersKey)
		openSpaceFolderMenuItem.isHidden = !usesCustomFolders
	}
	
	@IBAction func openSpaceFolder(_ sender: Any) {
		func ensureFolderExists(atURL url: URL) -> Bool {
			var isDirectory: ObjCBool = false
			if !fileman.fileExists(atPath: url.path, isDirectory: &isDirectory) {
				do {
					try fileman.createDirectory(at: url, withIntermediateDirectories: false)
					return true
				}
				catch {
					log("Alert of some kind")
					return false
				}
			}
			else if !isDirectory.boolValue {
				log("Alert: there is a file with that name!")
				return false
			}
			
			return true
		}
		
		let spacesURL = fileman.homeDirectoryForCurrentUser.appendingPathComponent("Spaces")
		
		if let spaceName = currentSpaceName {
			let thisSpaceURL = spacesURL.appendingPathComponent(spaceName.replacingOccurrences(of: "/", with: ":"))
			
			if ensureFolderExists(atURL: spacesURL) &&
			   ensureFolderExists(atURL: thisSpaceURL) {
				let task = Process()
				task.launchPath = "/usr/bin/osascript"
				task.arguments = ["-e", """
tell application "Finder"
	activate
	open ("\(thisSpaceURL.path)" as POSIX file)
end tell
"""]
				task.launch()
			}
		}
	}
	
	@IBAction func quitClicked(_ sender: NSMenuItem) {
		NSApplication.shared.terminate(self)
	}
	
	@IBAction func showPreferences(_ sender: Any) {
		NSApp.activate(ignoringOtherApps: true)
		preferenceWindow.makeKeyAndOrderFront(self)
	}
	
	@IBAction func openProject(_ sender: Any) {
		if let url = URL(string: "https://github.com/hyperjeff/NameSpace") {
			workspace.open(url)
		}
	}
	
	// MARK: - Table Methods -
	
	func numberOfRows(in tableView: NSTableView) -> Int {
		spaceNames.count
	}

	func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
		guard let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("NameCellID"), owner: self) as? NSTableCellView else {
			return nil
		}
		
		cell.textField?.tag = row
		cell.textField?.delegate = self
		cell.textField?.stringValue = spaceNames[row]
		
		return cell
	}
	
	func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
		if movingRows,
		   let data = info.draggingPasteboard.data(forType: .string),
		   let text = String(data: data, encoding: .utf8),
		   let incomingRow = Int(text) {
			
			let draggedName = spaceNames[incomingRow]
			spaceNames.remove(at: incomingRow)
			spaceNames.insert(draggedName, at: row - (incomingRow < row ? 1 : 0))
			
			updateMenuItems()
			saveSpaceNames()
			table.reloadData()
		}
		
		return movingRows
	}
	
	func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
		return .move
	}
	
	func tableView(_ tableView: NSTableView, writeRowsWith rowIndexes: IndexSet, to pboard: NSPasteboard) -> Bool {
		if let row = rowIndexes.first {
			pboard.declareTypes([.string], owner: self)
			pboard.setData("\(row)".data(using: .utf8)!, forType: .string)
			movingRows = true
		}
		
		return movingRows
	}
	
	func controlTextDidEndEditing(_ obj: Notification) {
		if let view = obj.userInfo?
			.filter({ ($0.value as AnyObject).isKind(of: NSTextView.self) })
			.first?.value as? NSTextView,
		   let textField = view.superview?.superview as? NSTextField {
			
			let row = textField.tag
			let name = view.string
			
			spaceNames[row] = name
			saveSpaceNames()
			updateActiveSpaceNumber()
			updateMenuItem(row, withName: name)
			table.reloadData()
			
			if row < table.numberOfRows - 1 {
				table.selectRowIndexes(NSIndexSet(index: row + 1) as IndexSet, byExtendingSelection: false)
				table.view(atColumn: 0, row: row + 1, makeIfNecessary: false)?.becomeFirstResponder()
			}
		}
	}
	
	func log(_ text: String) {
		print(text)
	}
	
}
