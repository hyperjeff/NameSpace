import Carbon
import AppKit

var mainApp: NSObject?
var keycodeMap: [Int : KeyInfo] = [:]
var spaceStack: [Int] = []
var spaceStackIndex = -1
let eventHotKeySignature: UInt32 = 1212828465

func hotkeyHandler(eventHandlerCall: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
	var hotkeyID = EventHotKeyID()
	
	let error = GetEventParameter(event, UInt32(kEventParamDirectObject), UInt32(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkeyID)
	
	if error != noErr { return error }
	
	switch (hotkeyID.signature - eventHotKeySignature) {
		case 0:
			if 1 < spaceStack.count && 0 < spaceStackIndex {
				spaceStackIndex -= 1
				keepTryingToHeadToSpace(atIndex: spaceStack[spaceStackIndex])
			}
			
		case 1:
			if spaceStackIndex < spaceStack.count - 1 {
				spaceStackIndex += 1
				keepTryingToHeadToSpace(atIndex: spaceStack[spaceStackIndex])
			}
			
		case 2:
			if let del = mainApp as? AppDelegate {
				del.openMenu()
				return noErr
			}
			
		default: return OSStatus(eventNotHandledErr)
	}
	
	return OSStatus(eventNotHandledErr)
}

func keepTryingToHeadToSpace(atIndex targetIndex: Int) {
	var activeSpaceID = -999
	var counter = 9
	
	DispatchQueue.global(qos: .background).async {
		while targetIndex != activeSpaceID - 2 && 0 < counter {
			DispatchQueue.main.async {
				headToSpace(atIndex: targetIndex)
			}
			
			usleep(270_000)
			
			if let spaceID = currentSpaceID() {
				activeSpaceID = spaceID
			}
			
			counter -= 1
		}
		
	}
}

func currentSpaceID() -> Int? {
	var activeSpaceID: Int?
	let connection = _CGSDefaultConnection()
	let displays = CGSCopyManagedDisplaySpaces(connection) as! [NSDictionary]
	let activeDisplay = CGSCopyActiveMenuBarDisplayIdentifier(connection) as! String
	
	for display in displays {
		if let current = display["Current Space"] as? [String : Any],
		   let displayID = display["Display Identifier"] as? String {
			
			if ["Main", activeDisplay].contains(displayID),
			   let managedSpaceID = current["ManagedSpaceID"] as? Int {
				activeSpaceID = managedSpaceID
				break
			}
		}
	}
	
	return activeSpaceID
}

func headToSpace(atIndex index: Int) {
	if keycodeMap.keys.contains(index),
	   let keymap = keycodeMap[index] {
		headToSpace(keymap: keymap)
	}
}

func headToSpace0(keymap: KeyInfo) { // this never worked under all circumstances
	if keymap.enabled {
		let maskLookup: [String : (CGKeyCode, CGEventFlags)] = [
			"shift"   : (57, .maskShift),
			"control" : (59, .maskControl),
			"option"  : (58, .maskAlternate),
			"command" : (55, .maskCommand),
		]
		
		let keycode = keymap.keycode
		let source = CGEventSource(stateID: .hidSystemState)
		
		var metaKeysRequired: [CGKeyCode] = []
		
		if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: true),
		   let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keycode), keyDown: false) {
		
			var keyDownFlags: [CGEventFlags] = []
			
			for (index, meta) in ["shift", "control", "option", "command"].enumerated() {
				if keymap.flags[index], let meta = maskLookup[meta] {
					metaKeysRequired.append(meta.0)
					keyDownFlags.append(meta.1)
				}
			}
			
			if !keyDownFlags.isEmpty {
				keyDown.flags = CGEventFlags(keyDownFlags)
			}
			
			let commandsDown = metaKeysRequired.map {
				CGEvent(keyboardEventSource: source, virtualKey: $0, keyDown: true)
			}
			let commandsUp = metaKeysRequired.map {
				CGEvent(keyboardEventSource: source, virtualKey: $0, keyDown: false)
			}
			
			commandsDown.forEach { $0?.post(tap: .cghidEventTap) }
			keyDown.post(tap: .cghidEventTap)
			keyUp.post(tap: .cghidEventTap)
			commandsUp.forEach { $0?.post(tap: .cghidEventTap) }
		}
	}
}

func headToSpace(keymap: KeyInfo) {
	if keymap.enabled {
		var metaKey = ""
		var metaKeys: [String] = []
		
		for (index, meta) in ["shift", "control", "option", "command"].enumerated() {
			if keymap.flags[index] {
				metaKeys.append("\(meta) down")
			}
		}
		
		if !metaKeys.isEmpty {
			if metaKeys.count == 1, let only = metaKeys.first {
				metaKey = " using " + only
			}
			else {
				metaKey = " using {" + metaKeys.joined(separator: ", ") + "}"
			}
		}
		
		var keycode = keymap.keycode
		
		if keymap.flags[3], // ← only remapping for items with command keys currently
		   let character = character(forKeyCode: CGKeyCode(keycode)),
		   let actualKeycode = keyboardCodeFromCharCode(charCode: character) {
			keycode = actualKeycode
		}
		
		print("tell application \"System Events\" to key code \(keycode)\(metaKey)")
		
		let task = Process()
		task.launchPath = "/usr/bin/osascript"
		task.arguments = ["-e", "tell application \"System Events\" to key code \(keycode)\(metaKey)"]
		task.launch()
	}
}

func character(forKeyCode keycode: CGKeyCode) -> String? {
	let keyboard = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
	let rawLayoutData = TISGetInputSourceProperty(keyboard, kTISPropertyUnicodeKeyLayoutData)
	let layoutData = unsafeBitCast(rawLayoutData, to: CFData.self)
	let layout = unsafeBitCast(CFDataGetBytePtr(layoutData), to: UnsafePointer<UCKeyboardLayout>.self)
	
	// Is this only needed if we are worried about the command key?
	let modifierKeyState         = UInt32(0)
	
	let keyaction                = UInt16(kUCKeyActionDisplay)
	let keyboardType             = UInt32(LMGetKbdType())
	let keyTranslateOptions      = OptionBits(kUCKeyTranslateNoDeadKeysBit)
	var deadKeyState: UInt32     = 0
	let maxStringLength: Int     = 4
	var chars: [UniChar]         = [0, 0, 0, 0]
	var actualStringLength: Int  = 1
	
	_ = UCKeyTranslate(layout, keycode, keyaction, modifierKeyState, keyboardType, keyTranslateOptions, &deadKeyState, maxStringLength, &actualStringLength, &chars)
	
	if let scalar = UnicodeScalar(chars[0]) {
		return "\(scalar)"
	}
	
	return nil
}

func keyboardCodeFromCharCode(charCode: String) -> Int? {
	switch (charCode) {
		case "a", "A": return kVK_ANSI_A
		case "b", "B": return kVK_ANSI_B
		case "c", "C": return kVK_ANSI_C
		case "d", "D": return kVK_ANSI_D
		case "e", "E": return kVK_ANSI_E
		case "f", "F": return kVK_ANSI_F
		case "g", "G": return kVK_ANSI_G
		case "h", "H": return kVK_ANSI_H
		case "i", "I": return kVK_ANSI_I
		case "j", "J": return kVK_ANSI_J
		case "k", "K": return kVK_ANSI_K
		case "l", "L": return kVK_ANSI_L
		case "m", "M": return kVK_ANSI_M
		case "n", "N": return kVK_ANSI_N
		case "o", "O": return kVK_ANSI_O
		case "p", "P": return kVK_ANSI_P
		case "q", "Q": return kVK_ANSI_Q
		case "r", "R": return kVK_ANSI_R
		case "s", "S": return kVK_ANSI_S
		case "t", "T": return kVK_ANSI_T
		case "u", "U": return kVK_ANSI_U
		case "v", "V": return kVK_ANSI_V
		case "w", "W": return kVK_ANSI_W
		case "x", "X": return kVK_ANSI_X
		case "y", "Y": return kVK_ANSI_Y
		case "z", "Z": return kVK_ANSI_Z
		case "0", "!": return kVK_ANSI_0
		case "1", "@": return kVK_ANSI_1
		case "2", "#": return kVK_ANSI_2
		case "3", "$": return kVK_ANSI_3
		case "4", "%": return kVK_ANSI_4
		case "5", "^": return kVK_ANSI_5
		case "6", "&": return kVK_ANSI_6
		case "7", "*": return kVK_ANSI_7
		case "8", "(": return kVK_ANSI_8
		case "9", ")": return kVK_ANSI_9

//		case NSPauseFunctionKey: return NSPauseFunctionKey;
//		case NSSelectFunctionKey: return VKEY_SELECT;
//		case NSPrintFunctionKey: return VKEY_PRINT;
//		case NSExecuteFunctionKey: return VKEY_EXECUTE;
//		case NSPrintScreenFunctionKey: return VKEY_SNAPSHOT;
//		case NSInsertFunctionKey: return VKEY_INSERT;
//		case NSF21FunctionKey: return VKEY_F21;
//		case NSF22FunctionKey: return VKEY_F22;
//		case NSF23FunctionKey: return VKEY_F23;
//		case NSF24FunctionKey: return VKEY_F24;
//		case NSScrollLockFunctionKey: return VKEY_SCROLL;
		// U.S. Specific mappings.  Mileage may vary.
		case ";", ":": return kVK_ANSI_Semicolon
		case "=", "+": return kVK_ANSI_Equal
		case ",", "<": return kVK_ANSI_Comma
		case "-", "_": return kVK_ANSI_Minus
		case ".", ">": return kVK_ANSI_Period
		case "/", "?": return kVK_ANSI_Slash
		case "`", "~": return kVK_ANSI_Grave
		case "[", "{": return kVK_ANSI_LeftBracket
		case "\\", "|": return kVK_ANSI_Backslash
		case "]", "}": return kVK_ANSI_RightBracket
		case "\'", "\"": return kVK_ANSI_Backslash
			
		default: return nil
	}
}

/*
 CGEventFlags
	.maskNonCoalesced	0x    100	      256
	.maskAlphaShift		0x 10_000	   65_536
	.maskShift			0x 20_000	  131_072
	.maskControl		0x 40_000	  262_144
	.maskAlternate		0x 80_000	  524_288
	.maskCommand		0x100_000	1_048_576
	.maskNumericPad		0x200_000	2_097_152
	.maskSecondaryFn	0x800_000	8_388_608
 
 ex: 537133057 → 0x20_040_001
     0x20_040_001 & 0xfff_ff00 = 0x40_000 = control (⌃)
*/
