import Testing
@testable import KhulumaCore

private let builtIn = AudioInput(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
private let yeti = AudioInput(uid: "AppleUSBAudioEngine:Blue:Yeti:1", name: "Yeti Stereo Microphone")
private let airPods = AudioInput(uid: "AA-BB-CC:input", name: "AirPods Pro")

struct MicrophoneChoiceTests {
  @Test func systemDefaultFollowsTheDefaultInput() {
    let choice = MicrophoneChoice(stored: nil, inputs: AudioInputs(devices: [builtIn, yeti], defaultUID: builtIn.uid))
    #expect(choice.followsSystemDefault && !choice.storedMissing)
    #expect(choice.effective == builtIn)
    #expect(choice.summary == "MacBook Pro Microphone")
    #expect(choice.note == nil)
    #expect(choice.options.map(\.title) == ["System Default", "MacBook Pro Microphone", "Yeti Stereo Microphone"])
    #expect(choice.options.map(\.checked) == [true, false, false])
    #expect(choice.options[0].uid == nil && choice.options[0].detail == "MacBook Pro Microphone")

    // The default moves (AirPods connect): the summary and System Default follow it.
    let moved = MicrophoneChoice(stored: nil, inputs: AudioInputs(devices: [builtIn, yeti, airPods], defaultUID: airPods.uid))
    #expect(moved.effective == airPods)
    #expect(moved.summary == "AirPods Pro")
    #expect(moved.options[0].detail == "AirPods Pro")
  }

  @Test func aConnectedChoiceIgnoresTheDefault() {
    let stored = AudioInput(uid: yeti.uid, name: "Old Yeti name")
    let choice = MicrophoneChoice(stored: stored, inputs: AudioInputs(devices: [builtIn, yeti], defaultUID: builtIn.uid))
    #expect(!choice.followsSystemDefault)
    #expect(choice.chosen == yeti && choice.effective == yeti)
    #expect(choice.summary == "Yeti Stereo Microphone")
    #expect(choice.options.map(\.checked) == [false, false, true])
    #expect(choice.options.allSatisfy { $0.connected })
  }

  @Test func aMissingChoiceStaysCheckedAndFallsBackToTheDefault() {
    let choice = MicrophoneChoice(stored: yeti, inputs: AudioInputs(devices: [builtIn], defaultUID: builtIn.uid))
    #expect(choice.storedMissing && choice.followsSystemDefault)
    #expect(choice.effective == builtIn)
    #expect(choice.summary == "MacBook Pro Microphone (Default)")
    #expect(choice.note == "Yeti Stereo Microphone isn’t connected. Takes use the system default until it is.")
    let missing = choice.options.last
    #expect(missing?.uid == yeti.uid && missing?.title == "Yeti Stereo Microphone")
    #expect(missing?.detail == "Not connected" && missing?.checked == true && missing?.connected == false)
    #expect(choice.options.filter { $0.checked }.count == 1)

    // It comes back: recording uses it again, with no stale entry.
    let back = MicrophoneChoice(stored: yeti, inputs: AudioInputs(devices: [builtIn, yeti], defaultUID: builtIn.uid))
    #expect(back.effective == yeti && back.options.count == 3)
  }

  @Test func noInputsAtAll() {
    let none = MicrophoneChoice(stored: nil, inputs: AudioInputs())
    #expect(none.effective == nil)
    #expect(none.summary == "No Input")
    #expect(none.options.count == 1 && none.options[0].detail == nil && none.options[0].checked)

    let missing = MicrophoneChoice(stored: yeti, inputs: AudioInputs())
    #expect(missing.effective == nil && missing.storedMissing)
    #expect(missing.summary == "System Default")
    #expect(missing.options.map(\.title) == ["System Default", "Yeti Stereo Microphone"])
  }

  @Test func aDefaultThatIsNotAnInputIsIgnored() {
    // The default UID can lag behind the device list during a switch.
    let choice = MicrophoneChoice(stored: nil, inputs: AudioInputs(devices: [builtIn], defaultUID: "gone"))
    #expect(choice.effective == nil)
    #expect(choice.options[0].detail == nil)
  }
}
