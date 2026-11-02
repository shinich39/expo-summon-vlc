import ExpoModulesCore
#if os(iOS)
import VLCKit
import UIKit
import AVFoundation
import AVKit
import MediaPlayer

private struct PlaylistItem {
  let id: String
  let url: URL
  let title: String?
  init(_ value: [String: String]) throws {
    guard Set(value.keys).isSubset(of: ["id", "uri", "title"]), let id = value["id"], !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          let uri = value["uri"], let url = URL(string: uri), url.scheme != nil else {
      throw NSError(domain: "ExpoSummonVlc.Playlist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist item"])
    }
    self.id = id
    self.url = url
    self.title = value["title"]
  }
  var dictionary: [String: String] {
    var result = ["id": id, "uri": url.absoluteString]
    if let title { result["title"] = title }
    return result
  }
}

private final class PlayerSession: NSObject {
  let videoOutput: ESVLCSessionOutput
  let frames: ESVLCSessionFrames
  var player: ESVLCSessionOutput { videoOutput }
  weak var output: PlayerView?
  var playlist: [URL] = []
  var playlistItems: [PlaylistItem] = []
  var currentIndex: Int = -1
  var trackRevision = UUID().uuidString
  private weak var trackMedia: VLCMedia?
  var onStateChange: (() -> Void)?
  var onProgress: (() -> Void)?
  var onTracksChange: (() -> Void)?
  var onPiPChange: ((Bool, String?) -> Void)?
  var onPiPWillStop: (() -> Void)?
  var pipGeneration = 0
  var pipExitTestGeneration: Int?
  var lastReportedState = ""
  var eventSequence = 0
  var progressSequence = 0
  private var progressTimer: Timer?
  private var lastProgressKey = ""
  var lastDuration: Int32 = 0
  var pendingSeek: Double?
  var pendingSeekFast = true
  var autoAdvanceArmed = false
  var playbackRate: Double = 1
  var volume: Int = 100
  var muted = false
  var audioDelayMillis: Int64 = 0
  var audioDelayApplied = false
  var failurePolicy = "stop" {
    didSet { if oldValue != failurePolicy { rebuildNativeOrder() } }
  }
  private var failedItems = Set<String>()
  var releaseInProgress = false
  var repeatMode = "off" {
    didSet { rebuildNativeOrder() }
  }
  var shuffleEnabled = false
  private var shuffleRemaining: [Int] = []
  private var playlistMedia: [VLCMedia] = []
  private var nativeOrder: [Int] = []
  private var nativeRepeatMode: String?
  private var nativeOrderDirty = false
  private var history: [Int] = []
  private var historyIndex = -1
  var transitionTimeoutMillis: Double = 10_000
  private var transitionPhase: String?
  private var transitionToken = 0
  private var pendingSelection: Int?
  private var transitionTargetIndex: Int?
  private var transitionFailed = false
  private var transitionMismatch = false
  private var transitionReady = false
  private var pauseAfterTransition = false
  private var audioInterruptionActive = false
  private var resumeAfterInterruption = false
  private var audioObservers: [NSObjectProtocol] = []
  var isTransitioning: Bool { transitionPhase != nil }
  init?(videoOutput: ESVLCSessionOutput?) {
    guard let videoOutput, let frames = ESVLCSessionFrames(nativePlayer: videoOutput.nativePlayer) else { return nil }
    self.videoOutput = videoOutput
    self.frames = frames
    super.init()
    videoOutput.mediaChanged = { [weak self] media in self?.mediaChanged(media) }
    videoOutput.stateChanged = { [weak self] failed, media in self?.mediaPlayerStateChanged(failed: failed, media: media) }
    videoOutput.lengthChanged = { [weak self] length in self?.mediaPlayerLengthChanged(length) }
    videoOutput.timeChanged = { [weak self] in self?.mediaPlayerTimeChanged() }
    videoOutput.tracksChanged = { [weak self] in self?.onTracksChange?() }
    videoOutput.seekFinished = { [weak self] in
      guard let self else { return }
      SessionPiP.shared.playbackChanged(self, force: true)
    }
    let center = NotificationCenter.default
    audioObservers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      self?.handleAudioInterruption(notification)
    })
    audioObservers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      self?.handleAudioRouteChange(notification)
    })
  }

  private func activateAudio() throws {
    guard !audioInterruptionActive else {
      throw NSError(domain: "ExpoSummonVlc.Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Audio is interrupted"])
    }
    let audio = AVAudioSession.sharedInstance()
    try audio.setCategory(.playback, mode: .moviePlayback)
    try audio.setActive(true)
  }

  private func handleAudioInterruption(_ notification: Notification) {
    guard !releaseInProgress,
          let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .began {
      guard !audioInterruptionActive else { return }
      audioInterruptionActive = true
      resumeAfterInterruption = player.isPlaying || (isTransitioning && !pauseAfterTransition)
      if isTransitioning { pauseAfterTransition = true }
      else if player.isPlaying { player.pause() }
    } else if type == .ended {
      guard audioInterruptionActive else { return }
      audioInterruptionActive = false
      let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
      let shouldResume = resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
      resumeAfterInterruption = false
      if shouldResume { setPlaying(true) }
    }
    onStateChange?()
  }

  private func handleAudioRouteChange(_ notification: Notification) {
    guard !releaseInProgress,
          let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
    resumeAfterInterruption = false
    setPlaying(false)
    onStateChange?()
  }

  func cancelAudioResume() { resumeAfterInterruption = false }

  func startProgressUpdates() {
    progressTimer?.invalidate()
    let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
      guard let self, !self.releaseInProgress, !self.isTransitioning,
            self.state == "playing" || self.state == "paused", self.player.media != nil else { return }
      if !self.playlistMedia.isEmpty {
        guard self.playlistMedia.indices.contains(self.currentIndex), self.player.media === self.playlistMedia[self.currentIndex] else { return }
      }
      let duration = max(self.lastDuration, self.player.durationMillis)
      let position = max(0, self.player.positionMillis)
      let key = "\(self.trackRevision):\(self.currentIndex):\(position):\(duration)"
      guard key != self.lastProgressKey else { return }
      self.lastProgressKey = key
      self.progressSequence += 1
      self.onProgress?()
    }
    RunLoop.main.add(timer, forMode: .common)
    progressTimer = timer
  }

  func preparePlaylistReplacement() {
    cancelAudioResume()
    trackRevision = UUID().uuidString
    cancelTransition()
    autoAdvanceArmed = false
    pendingSeek = nil
    lastDuration = 0
    player.stop()
  }

  func setPlaylist(_ urls: [URL], items: [PlaylistItem]? = nil) throws {
    let media = urls.compactMap { VLCMedia(url: $0) }
    guard media.count == urls.count else {
      throw NSError(domain: "ExpoSummonVlc", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create playlist media"])
    }
    playlist = urls
    failedItems.removeAll()
    playlistItems = try items ?? urls.map { try PlaylistItem(["id": UUID().uuidString, "uri": $0.absoluteString]) }
    playlistMedia = media
    nativeOrder = []
    nativeRepeatMode = nil
    nativeOrderDirty = false
    currentIndex = -1
    resetOrder()
    rebuildNativeOrder()
  }

  func clearPlaylist() {
    playlist = []
    playlistItems = []
    playlistMedia = []
    nativeOrder = []
    nativeRepeatMode = nil
    nativeOrderDirty = false
    currentIndex = -1
    resetOrder()
  }

  func editPlaylist(_ items: [PlaylistItem]) throws {
    guard !isTransitioning else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 2, userInfo: [NSLocalizedDescriptionKey: "Wait for the current transition to finish"]) }
    let old = playlistItems
    let oldMedia = playlistMedia
    let oldCurrentID = old.indices.contains(currentIndex) ? old[currentIndex].id : nil
    var media: [VLCMedia] = []
    for item in items {
      if let index = old.firstIndex(where: { $0.id == item.id }) { media.append(oldMedia[index]) }
      else if let newMedia = VLCMedia(url: item.url) { media.append(newMedia) }
      else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create playlist media"]) }
    }
    let newIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    let mappedHistory = history.enumerated().compactMap { offset, index -> (Int, Int)? in
      guard old.indices.contains(index), let mapped = newIndices[old[index].id] else { return nil }
      return (offset, mapped)
    }
    let mappedRemaining = shuffleRemaining.compactMap { old.indices.contains($0) ? newIndices[old[$0].id] : nil }
    if let oldCurrentID, newIndices[oldCurrentID] == nil {
      cancelAudioResume()
      cancelTransition()
      autoAdvanceArmed = false
      player.stop()
      lastDuration = 0
      audioDelayApplied = false
      trackRevision = UUID().uuidString
    }
    playlistItems = items
    failedItems.formIntersection(Set(items.map(\.id)))
    playlist = items.map(\.url)
    playlistMedia = media
    currentIndex = oldCurrentID.flatMap { newIndices[$0] } ?? -1
    history = mappedHistory.map { $0.1 }
    historyIndex = mappedHistory.filter { $0.0 <= historyIndex }.count - 1
    shuffleRemaining = mappedRemaining + items.indices.filter { index in !old.contains(where: { $0.id == items[index].id }) }.shuffled()
    nativeOrder = []
    nativeRepeatMode = nil
    if items.isEmpty { videoOutput.setMediaItems([]) } else { rebuildNativeOrder() }
    onStateChange?()
    ControlCenter.shared.refresh(self)
  }

  private func rebuildNativeOrder(force: Bool = false) {
    guard !playlistMedia.isEmpty else { return }
    if isTransitioning && !transitionReady && !force {
      nativeOrderDirty = true
      return
    }
    nativeOrderDirty = false
    var order: [Int]
    if shuffleEnabled && playlist.indices.contains(currentIndex) {
      if shuffleRemaining.isEmpty && historyIndex + 1 >= history.count && repeatMode == "all" && playlist.count > 1 {
        shuffleRemaining = playlist.indices.filter { $0 != currentIndex }.shuffled()
      }
      let forward = historyIndex + 1 < history.count ? Array(history[(historyIndex + 1)...]) : []
      order = [currentIndex] + forward + Array(shuffleRemaining.reversed())
      // Keep the currently playing item in the new list until the requested
      // selection becomes active, so replacing the list does not stop it.
      if let playing = player.media, let playingIndex = playlistMedia.firstIndex(where: { $0 === playing }), !order.contains(playingIndex) {
        order.insert(playingIndex, at: 0)
      }
      var seen = Set<Int>()
      order = order.filter { playlist.indices.contains($0) && seen.insert($0).inserted }
    } else {
      order = Array(playlist.indices)
    }
    // Shuffle produces a new cycle explicitly; native repeat-one is still used.
    let mode = repeatMode == "all" && (failurePolicy == "skip" || (shuffleEnabled && playlist.count > 1)) ? "off" : repeatMode
    guard order != nativeOrder || mode != nativeRepeatMode else { return }
    nativeOrder = order
    nativeRepeatMode = mode
    videoOutput.setListRepeatMode(mode)
    videoOutput.setMediaItems(order.map { playlistMedia[$0] })
  }

  func mediaChanged(_ media: VLCMedia) {
    guard !releaseInProgress, !transitionMismatch, let index = playlistMedia.firstIndex(where: { $0 === media }) else { return }
    if isTransitioning && index != transitionTargetIndex {
      transitionReady = false
      return
    }
    if trackMedia !== media {
      trackMedia = media
      trackRevision = UUID().uuidString
    }
    audioDelayApplied = player.setAudioDelay(millis: audioDelayMillis)
    if isTransitioning {
      transitionReady = true
    } else if index != currentIndex {
      currentIndex = index
      lastDuration = 0
      if shuffleEnabled { recordSelection(index) }
      autoAdvanceArmed = false
      if shuffleEnabled { rebuildNativeOrder() }
    }
    onStateChange?()
    SessionPiP.shared.playbackChanged(self)
    ControlCenter.shared.refresh(self)
  }

  func mediaPlayerStateChanged(failed: Bool, media: VLCMedia?) {
    guard !releaseInProgress else { return }
    if failed, transitionPhase != nil, let target = transitionTargetIndex,
       playlistMedia.indices.contains(target), media === playlistMedia[target] {
      transitionToken += 1
      transitionPhase = nil
      transitionTargetIndex = nil
      transitionReady = false
      if pendingSelection != nil { beginTransition(); return }
      transitionFailed = true
      transitionMismatch = false
      autoAdvanceArmed = false
      onStateChange?()
      return
    }
    if player.isPlaying && !audioDelayApplied {
      audioDelayApplied = player.setAudioDelay(millis: audioDelayMillis)
    }
    applyPendingSeek()
    SessionPiP.shared.playbackChanged(self)
    ControlCenter.shared.refresh(self)
    onStateChange?()
  }

  func mediaPlayerLengthChanged(_ length: Int64) {
    DispatchQueue.main.async { [weak self] in
      guard let self, !self.releaseInProgress else { return }
      if !self.isTransitioning && length > 0 { self.lastDuration = Int32(clamping: length) }
      SessionPiP.shared.durationChanged(self)
      ControlCenter.shared.refresh(self)
    }
  }

  func mediaPlayerTimeChanged() {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if self.state == "playing", self.playlistMedia.indices.contains(self.currentIndex),
         self.player.media === self.playlistMedia[self.currentIndex], self.player.positionMillis >= 1000 {
        self.failedItems.removeAll()
      }
      self.applyPendingSeek()
      SessionPiP.shared.clockChanged(self)
      ControlCenter.shared.refresh(self)
    }
  }

  func applyPendingSeek() {
    guard !releaseInProgress else { return }
    guard let target = pendingSeek, videoOutput.nativeIsSeekable(), state == "playing" || state == "paused" else { return }
    let duration = player.durationMillis
    guard duration > 0 else { return }
    pendingSeek = nil
    let fast = pendingSeekFast
    pendingSeekFast = true
    videoOutput.seek(toPosition: Float(min(target / Double(duration), 1)), fast: fast)
  }

  func seek(to millis: Double, fast: Bool = true) throws {
    guard millis.isFinite, millis >= 0 else {
      throw NSError(domain: "ExpoSummonVlc", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid seek position"])
    }
    let duration = max(player.durationMillis, lastDuration)
    guard !isTransitioning, duration > 0, videoOutput.nativeIsSeekable() || state == "ended" else {
      throw NSError(domain: "ExpoSummonVlc", code: 6, userInfo: [NSLocalizedDescriptionKey: "Media is not seekable"])
    }
    let target = min(millis, Double(max(0, duration - 1)))
    if state == "ended" {
      try activateAudio()
      pendingSeek = target
      pendingSeekFast = fast
      player.play()
      applyPendingSeek()
    } else {
      videoOutput.seek(toPosition: Float(target / Double(duration)), fast: fast)
    }
  }

  var state: String {
    if transitionPhase != nil { return "preparing" }
    if transitionFailed { return "error" }
    switch player.state {
    case .nothingSpecial: return "stopped"
    case .opening, .stopping: return "preparing"
    case .playing: return "playing"
    case .paused: return "paused"
    case .stopped: return autoAdvanceArmed ? "ended" : "stopped"
    case .error: return "error"
    @unknown default: return "unknown"
    }
  }
  var currentItemID: String? {
    playlistItems.indices.contains(currentIndex) ? playlistItems[currentIndex].id : nil
  }
  var playbackError: [String: String]? {
    guard state == "error" else { return nil }
    if transitionMismatch {
      return ["code": "TRANSITION_FAILED", "message": "The player switched to a different playlist item."]
    }
    return transitionFailed
      ? ["code": "TRANSITION_FAILED", "message": "Could not complete the playlist transition."]
      : ["code": "PLAYBACK_FAILED", "message": "The media player reported a playback error."]
  }

  func cancelTransition() {
    pendingSeek = nil
    transitionToken += 1
    transitionPhase = nil
    pendingSelection = nil
    transitionTargetIndex = nil
    transitionFailed = false
    transitionMismatch = false
    pauseAfterTransition = false
  }

  private func waitForTransition(_ token: Int, deadline: Date) {
    guard token == transitionToken, let phase = transitionPhase else { return }
    if phase == "starting" && transitionReady && player.isPlaying,
       let target = transitionTargetIndex, playlistMedia.indices.contains(target),
       player.media === playlistMedia[target] {
      transitionPhase = nil
      transitionTargetIndex = nil
      if pendingSelection != nil {
        beginTransition()
        return
      }
      autoAdvanceArmed = currentIndex >= 0 && playlist.indices.contains(currentIndex)
      rebuildNativeOrder()
      if pauseAfterTransition { pauseAfterTransition = false; player.pause() }
      onStateChange?()
      return
    }
    if Date() >= deadline {
      let target = transitionTargetIndex
      let actual = player.media
      let mismatch = target.map { playlistMedia.indices.contains($0) && actual != nil && actual !== playlistMedia[$0] } ?? false
      transitionPhase = nil
      transitionTargetIndex = nil
      if pendingSelection != nil { beginTransition(); return }
      transitionMismatch = mismatch
      transitionFailed = true
      autoAdvanceArmed = false
      if mismatch { videoOutput.stopPlaylist() }
      onStateChange?()
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.waitForTransition(token, deadline: deadline)
    }
  }

  private func beginTransition() {
    guard transitionPhase == nil, pendingSelection != nil else { return }
    transitionFailed = false
    transitionMismatch = false
    transitionToken += 1
    let token = transitionToken
    guard let index = pendingSelection, playlistMedia.indices.contains(index) else {
      transitionFailed = true
      pendingSelection = nil
      onStateChange?()
      return
    }
    pendingSelection = nil
    transitionPhase = "starting"
    transitionTargetIndex = index
    transitionReady = false
    // Keep only the requested media in the native list until playback starts.
    // Otherwise libVLC may automatically play a later item when this one fails.
    videoOutput.setListRepeatMode("off")
    videoOutput.setMediaItems([playlistMedia[index]])
    nativeOrder = [index]
    nativeRepeatMode = "off"
    nativeOrderDirty = true
    videoOutput.playListItem(at: 0)
    waitForTransition(token, deadline: Date().addingTimeInterval(transitionTimeoutMillis / 1000))
  }

  func resetOrder() {
    history = currentIndex >= 0 && playlist.indices.contains(currentIndex) ? [currentIndex] : []
    historyIndex = history.count - 1
    shuffleRemaining = playlist.indices.filter { $0 != currentIndex }.shuffled()
  }
  func setShuffle(_ enabled: Bool) {
    guard shuffleEnabled != enabled else { return }
    shuffleEnabled = enabled
    resetOrder()
    rebuildNativeOrder()
  }
  private func recordSelection(_ index: Int) {
    if historyIndex + 1 < history.count { history.removeSubrange((historyIndex + 1)..<history.count) }
    if history.last != index || history.isEmpty { history.append(index) }
    if history.count > 1000 { history.removeFirst(history.count - 1000) }
    historyIndex = history.count - 1
    shuffleRemaining.removeAll { $0 == index }
  }
  var canNext: Bool {
    guard !playlist.isEmpty else { return false }
    if currentIndex < 0 { return true }
    if shuffleEnabled { return historyIndex + 1 < history.count || !shuffleRemaining.isEmpty || repeatMode == "all" }
    return currentIndex + 1 < playlist.count || repeatMode == "all"
  }
  var canPrevious: Bool {
    guard playlist.indices.contains(currentIndex) else { return false }
    if shuffleEnabled { return historyIndex > 0 }
    return currentIndex > 0 || repeatMode == "all"
  }
  func select(_ index: Int, record: Bool = true, preservingFailures: Bool = false) throws {
    guard playlist.indices.contains(index) else {
      throw NSError(domain: "ExpoSummonVlc", code: 4, userInfo: [NSLocalizedDescriptionKey: "No playlist item in that direction"])
    }
    try activateAudio()
    if !preservingFailures { failedItems.removeAll() }
    trackRevision = UUID().uuidString
    resumeAfterInterruption = false
    let wasEnded = player.state == .stopped && currentIndex == index
    if record && shuffleEnabled { recordSelection(index) }
    pauseAfterTransition = false
    autoAdvanceArmed = false
    if !transitionFailed && transitionPhase == nil && index == currentIndex && wasEnded {
      pendingSeek = 0
      pendingSeekFast = true
      player.play()
      applyPendingSeek()
      return
    }
    if !transitionFailed && transitionPhase == nil && index == currentIndex && player.isPlaying {
      try seek(to: 0)
      autoAdvanceArmed = true
      return
    }
    pendingSeek = nil
    lastDuration = 0
    currentIndex = index
    pendingSelection = index
    if transitionPhase == nil { beginTransition() }
  }
  func setPlaying(_ playing: Bool) {
    if !playing { resumeAfterInterruption = false }
    if playing {
      do { try activateAudio() }
      catch { onStateChange?(); return }
    }
    if transitionPhase != nil {
      pauseAfterTransition = !playing
      return
    }
    if playing {
      if state == "ended" { try? seek(to: 0) } else { player.play() }
    } else if player.isPlaying { player.pause() }
  }
  func playFromAPI() throws {
    try activateAudio()
    setPlaying(true)
  }
  @discardableResult
  func next(automatic: Bool = false) throws -> Bool {
    if automatic && repeatMode == "one" && playlist.indices.contains(currentIndex) {
      try select(currentIndex, record: false, preservingFailures: true)
      return true
    }
    guard canNext else { return false }
    if currentIndex < 0 { try select(0, preservingFailures: automatic); return true }
    if shuffleEnabled {
      if historyIndex + 1 < history.count {
        historyIndex += 1
        try select(history[historyIndex], record: false, preservingFailures: automatic)
      } else {
        if shuffleRemaining.isEmpty {
          shuffleRemaining = playlist.indices.filter { $0 != currentIndex }.shuffled()
          if shuffleRemaining.isEmpty { shuffleRemaining = [currentIndex] }
        }
        let index = shuffleRemaining.removeLast()
        try select(index, preservingFailures: automatic)
      }
    } else { try select((currentIndex + 1) % playlist.count, preservingFailures: automatic) }
    return true
  }
  @discardableResult
  func previous() throws -> Bool {
    guard canPrevious else { return false }
    if shuffleEnabled {
      historyIndex -= 1
      try select(history[historyIndex], record: false)
    } else { try select((currentIndex - 1 + playlist.count) % playlist.count) }
    return true
  }

  func handlePlaybackState(_ state: String) {
    guard transitionPhase == nil, !transitionFailed else { return }
    if state == "playing" {
      autoAdvanceArmed = currentIndex >= 0 && currentIndex < playlist.count
    } else if state == "ended", autoAdvanceArmed, failurePolicy == "skip", repeatMode == "all",
              currentIndex == playlist.count - 1 || shuffleEnabled {
      autoAdvanceArmed = false
      do { _ = try next(automatic: true) }
      catch { NSLog("ExpoSummonVlc: Could not repeat the playlist") }
    }
  }

  func handlePlaybackFailure() {
    guard !transitionMismatch, failurePolicy == "skip", let itemID = currentItemID, failedItems.insert(itemID).inserted else { return }
    let candidates: [Int]
    if shuffleEnabled {
      let remaining = Array(shuffleRemaining.reversed()).filter { playlistItems.indices.contains($0) && !failedItems.contains(playlistItems[$0].id) }
      candidates = remaining + (repeatMode == "all" ? playlist.indices.filter { !failedItems.contains(playlistItems[$0].id) } : [])
    } else if repeatMode == "all" {
      candidates = (1...max(1, playlist.count)).map { (currentIndex + $0) % playlist.count }.filter { !failedItems.contains(playlistItems[$0].id) }
    } else {
      candidates = playlist.indices.filter { $0 > currentIndex && !failedItems.contains(playlistItems[$0].id) }
    }
    guard let next = candidates.first else {
      autoAdvanceArmed = false
      transitionFailed = true
      videoOutput.stopPlaylist()
      return
    }
    do { try select(next, preservingFailures: true) }
    catch { NSLog("ExpoSummonVlc: Could not advance after playback failure") }
  }

  func release(completion: (() -> Void)? = nil) {
    releaseInProgress = true
    audioObservers.forEach { NotificationCenter.default.removeObserver($0) }
    audioObservers.removeAll()
    resumeAfterInterruption = false
    cancelTransition()
    onStateChange = nil
    progressTimer?.invalidate()
    progressTimer = nil
    onProgress = nil
    onPiPChange = nil
    onPiPWillStop = nil
    onTracksChange = nil
    videoOutput.mediaChanged = nil
    videoOutput.stateChanged = nil
    videoOutput.timeChanged = nil
    videoOutput.seekFinished = nil
    videoOutput.tracksChanged = nil
    videoOutput.lengthChanged = nil
    SessionPiP.shared.detach(self)
    output = nil
    let outputToRelease = videoOutput
    outputToRelease.stopAsync {
      func finishWhenStopped() {
        guard outputToRelease.isPlayerStopped() else {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: finishWhenStopped)
          return
        }
        self.frames.shutdown()
        outputToRelease.shutdown()
        completion?()
      }
      finishWhenStopped()
    }
  }
}
private enum Sessions {
  static var items: [String: PlayerSession] = [:]
  static var pendingCleanup = 0

  static func get(_ id: String) throws -> PlayerSession {
    guard let session = items[id] else {
      throw NSError(domain: "ExpoSummonVlc", code: 1, userInfo: [NSLocalizedDescriptionKey: "Session does not exist or has been released"])
    }
    guard !session.releaseInProgress else {
      throw NSError(domain: "ExpoSummonVlc", code: 15, userInfo: [NSLocalizedDescriptionKey: "Session release is in progress"])
    }
    return session
  }
}

// MPNowPlayingInfoCenter and MPRemoteCommandCenter are shared by the app.
// Keep exactly one session in control and remove only handlers registered here.
private final class ControlCenter {
  static let shared = ControlCenter()
  private weak var session: PlayerSession?
  private var targets: [(MPRemoteCommand, Any)] = []

  func setEnabled(_ enabled: Bool, session candidate: PlayerSession) throws {
    if !enabled {
      if session === candidate { clear() }
      return
    }
    guard session == nil || session === candidate else {
      throw NSError(domain: "ExpoSummonVlc", code: 17, userInfo: [NSLocalizedDescriptionKey: "Another session already controls the iOS Control Center"])
    }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try AVAudioSession.sharedInstance().setActive(true)
    if session == nil {
      session = candidate
      registerCommands()
    }
    refresh(candidate)
  }

  private func register(_ command: MPRemoteCommand, action: @escaping (PlayerSession, MPRemoteCommandEvent) -> Void) {
    let token = command.addTarget { [weak self] event in
      guard let self, let candidate = self.session else { return .commandFailed }
      DispatchQueue.main.async { [weak self, weak candidate] in
        guard let self, let candidate, self.session === candidate, !candidate.releaseInProgress else { return }
        action(candidate, event)
        self.refresh(candidate)
      }
      return .success
    }
    targets.append((command, token))
  }

  private func registerCommands() {
    let commands = MPRemoteCommandCenter.shared()
    register(commands.playCommand) { session, _ in session.setPlaying(true) }
    register(commands.pauseCommand) { session, _ in session.setPlaying(false) }
    register(commands.togglePlayPauseCommand) { session, _ in session.setPlaying(!session.player.isPlaying) }
    register(commands.nextTrackCommand) { session, _ in _ = try? session.next() }
    register(commands.previousTrackCommand) { session, _ in _ = try? session.previous() }
    register(commands.changePlaybackPositionCommand) { session, event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return }
      try? session.seek(to: event.positionTime * 1000)
    }
  }

  func refresh(_ candidate: PlayerSession) {
    guard session === candidate, !candidate.releaseInProgress else { return }
    let media = candidate.player.media
    let playlistTitle = candidate.playlistItems.indices.contains(candidate.currentIndex) ? candidate.playlistItems[candidate.currentIndex].title : nil
    let title = (playlistTitle ?? media?.metaData.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
    let fallback = media?.url?.deletingPathExtension().lastPathComponent
    let position = candidate.isTransitioning ? 0 : max(0, candidate.player.positionMillis)
    let duration = candidate.isTransitioning ? 0 : max(candidate.lastDuration, candidate.player.durationMillis)
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: (title?.isEmpty == false ? title : nil) ?? (fallback?.isEmpty == false ? fallback : nil) ?? "Media",
      MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(position) / 1000,
      MPNowPlayingInfoPropertyPlaybackRate: candidate.state == "playing" ? candidate.playbackRate : 0.0,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(duration) / 1000 }
    if let artist = media?.metaData.artist, !artist.isEmpty { info[MPMediaItemPropertyArtist] = artist }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.isEnabled = true
    commands.pauseCommand.isEnabled = true
    commands.togglePlayPauseCommand.isEnabled = true
    commands.nextTrackCommand.isEnabled = candidate.canNext
    commands.previousTrackCommand.isEnabled = candidate.canPrevious
    commands.changePlaybackPositionCommand.isEnabled = candidate.player.isSeekable
  }

  func clear(_ candidate: PlayerSession? = nil) {
    if let candidate, session !== candidate { return }
    guard session != nil || !targets.isEmpty else { return }
    for (command, token) in targets { command.removeTarget(token) }
    targets.removeAll()
    session = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
}

// Both completion and timeout are delivered on the main queue.
private final class PlayerReleaseTicket {
  let promise: Promise
  var settled = false
  init(_ promise: Promise) { self.promise = promise }
}

// One independent analysis job at a time; all state is confined to the main queue.
private final class MediaAnalysis: NSObject, VLCMediaDelegate {
  static let shared = MediaAnalysis()
  private final class Job {
    let id: String
    let promise: Promise
    var media: VLCMedia?
    var generator: AVAssetImageGenerator?
    var deadline: DispatchWorkItem?
    var completed = false
    init(id: String, promise: Promise) { self.id = id; self.promise = promise }
  }
  private var job: Job?

  private func begin(_ id: String, timeout: Int, promise: Promise) -> Job? {
    guard !id.isEmpty, (100...120000).contains(timeout) else {
      promise.reject("ERR_MEDIA_ARGUMENT", "A request ID and a timeout between 100 and 120000 ms are required")
      return nil
    }
    guard job == nil else {
      promise.reject("ERR_MEDIA_BUSY", "Another media analysis job is still running")
      return nil
    }
    let next = Job(id: id, promise: promise)
    job = next
    let deadline = DispatchWorkItem { [weak self, weak next] in
      guard let self, let next else { return }
      self.cancel(next, code: "ERR_MEDIA_TIMEOUT", message: "Media analysis timed out")
    }
    next.deadline = deadline
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(timeout), execute: deadline)
    return next
  }
  private func finish(_ current: Job, value: Any? = nil, code: String? = nil, message: String = "") {
    guard job === current, !current.completed else { return }
    current.completed = true
    current.deadline?.cancel()
    current.media?.delegate = nil
    if let code { current.promise.reject(code, message) } else { current.promise.resolve(value) }
    job = nil
  }
  private func cancel(_ current: Job, code: String, message: String) {
    guard job === current, !current.completed else { return }
    current.completed = true
    current.deadline?.cancel()
    current.promise.reject(code, message)
    if let generator = current.generator {
      // Hold the slot until AVFoundation reports completion of the cancelled request.
      generator.cancelAllCGImageGeneration()
    } else {
      current.media?.delegate = nil
      if let media = current.media { ESVLCFrameProbe.cancelParsingMedia(media) }
      job = nil
    }
  }
  func cancel(id: String) -> Bool {
    guard let job, job.id == id, !job.completed else { return false }
    cancel(job, code: "ERR_MEDIA_CANCELLED", message: "Media analysis was cancelled")
    return true
  }
  func shutdown() {
    guard let job, !job.completed else { return }
    cancel(job, code: "ERR_MEDIA_CANCELLED", message: "The module was destroyed")
  }
  func inspect(id: String, uri: String, timeout: Int, promise: Promise) {
    guard let url = URL(string: uri), let scheme = url.scheme, ["file", "http", "https"].contains(scheme.lowercased()) else {
      promise.reject("ERR_MEDIA_ARGUMENT", "Use a file, http, or https URI")
      return
    }
    guard let current = begin(id, timeout: timeout, promise: promise) else { return }
    guard let media = VLCMedia(url: url) else { finish(current, code: "ERR_MEDIA_PARSE", message: "Could not create media"); return }
    current.media = media
    media.delegate = self
    if ESVLCFrameProbe.parseMedia(media, options: url.isFileURL ? 0 : 1, timeout: Int32(timeout)) != 0 {
      finish(current, code: "ERR_MEDIA_PARSE", message: "Could not start media parsing")
    }
  }
  func mediaDidFinishParsing(_ media: VLCMedia) {
    DispatchQueue.main.async {
      guard let current = self.job, current.media === media, !current.completed else { return }
      guard media.parsedStatus.rawValue == 6 else {
        self.finish(current, code: "ERR_MEDIA_PARSE", message: "Media parsing failed or timed out (status \(media.parsedStatus.rawValue))")
        return
      }
      let tracks: [[String: Any]] = media.tracksInformation.map { source in
        var track: [String: Any] = ["type": source.video != nil ? "video" : (source.audio != nil ? "audio" : "unknown"), "id": source.identifier, "bitrate": source.bitrate, "codec": source.codecName()]
        if let language = source.language { track["language"] = language }
        if let video = source.video {
          track["width"] = video.width
          track["height"] = video.height
          if video.frameRateDenominator > 0 { track["frameRate"] = Double(video.frameRate) / Double(video.frameRateDenominator) }
        }
        if let audio = source.audio { track["channels"] = audio.channelsNumber; track["sampleRate"] = audio.rate }
        return track
      }
      let duration = media.length.intValue
      self.finish(current, value: ["durationMillis": duration > 0 ? duration as Any : NSNull(), "title": media.metaData.title as Any? ?? NSNull(), "tracks": tracks])
    }
  }
  func thumbnail(id: String, uri: String, position: Double, timeout: Int, promise: Promise) {
    guard let url = URL(string: uri), url.isFileURL, position.isFinite, position >= 0, position <= 1_000_000_000_000 else {
      promise.reject("ERR_MEDIA_ARGUMENT", "Thumbnail requires a local file URI and a valid non-negative position")
      return
    }
    guard let current = begin(id, timeout: timeout, promise: promise) else { return }
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 640, height: 640)
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    current.generator = generator
    let time = CMTime(seconds: position / 1000, preferredTimescale: 600)
    generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, actualTime, result, error in
      var outputURL: URL?
      var imageSize = CGSize.zero
      var outputError: String?
      if result == .succeeded, let image {
        imageSize = CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("summon-vlc-\(UUID().uuidString).jpg")
        do {
          guard let bytes = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { throw NSError(domain: "ExpoSummonVlc", code: 1) }
          try bytes.write(to: destination, options: .atomic)
          outputURL = destination
        } catch { outputError = "Could not write thumbnail" }
      } else { outputError = error?.localizedDescription ?? "Could not extract a thumbnail" }
      let resultURL = outputURL
      let resultSize = imageSize
      let resultError = outputError
      DispatchQueue.main.async {
        guard self.job === current else { if let resultURL { try? FileManager.default.removeItem(at: resultURL) }; return }
        if current.completed {
          if let resultURL { try? FileManager.default.removeItem(at: resultURL) }
          self.job = nil
          return
        }
        guard let resultURL else { self.finish(current, code: "ERR_THUMBNAIL", message: resultError ?? "Thumbnail failed"); return }
        let seconds = CMTimeGetSeconds(actualTime)
        self.finish(current, value: ["uri": resultURL.absoluteString, "requestedPositionMillis": position, "actualPositionMillis": seconds.isFinite ? seconds * 1000 as Any : NSNull(), "width": Int(resultSize.width), "height": Int(resultSize.height)])
      }
    }
  }
}

// Experimental probe has an independent player and is never used by a session.
private enum FrameProbe {
  static let queue = DispatchQueue(label: "expo.summonvlc.frame-probe")
  static let displayLayer = AVSampleBufferDisplayLayer()
  static var current: ESVLCFrameProbe?
}

// Separate feasibility gate: this controller never represents a PlayerSession.
private final class FrameProbePiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  static let shared = FrameProbePiP()
  private var controller: AVPictureInPictureController?
  private var timebase: CMTimebase?
  private var timer: Timer?
  private var duration: Int64 = 0
  private var paused = true
  private var restored = false
  private(set) var starting = false
  private(set) var error: String?
  weak var preview: FrameProbePreview?
  private var retainedPreview: FrameProbePreview?

  func prepare() {
    guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
    var base: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
    if let base {
      timebase = base
      FrameProbe.displayLayer.controlTimebase = base
      CMTimebaseSetRate(base, rate: 0)
    }
    let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: FrameProbe.displayLayer, playbackDelegate: self)
    let pip = AVPictureInPictureController(contentSource: source)
    pip.delegate = self
    controller = pip
  }

  func refresh() {
    let snapshot: (Int64, Int64, Bool) = FrameProbe.queue.sync {
      guard let probe = FrameProbe.current else { return (0, 0, false) }
      return (probe.positionMillis(), probe.durationMillis(), probe.isPlaying())
    }
    if let timebase { CMTimebaseSetTime(timebase, time: CMTime(value: snapshot.0, timescale: 1000)) }
    let changed = duration != snapshot.1 || paused == snapshot.2
    duration = snapshot.1
    paused = !snapshot.2
    if changed { controller?.invalidatePlaybackState() }
  }

  func start() throws {
    prepare()
    guard let controller else { throw failure("Picture in Picture is not supported on this device") }
    guard FrameProbe.queue.sync(execute: { FrameProbe.current != nil }) else { throw failure("Start the frame probe first") }
    guard let preview, preview.window != nil else { throw failure("The frame probe preview must be visible") }
    guard !starting && !controller.isPictureInPictureActive else { return }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try AVAudioSession.sharedInstance().setActive(true)
    refresh()
    guard controller.isPictureInPicturePossible else { throw failure("Picture in Picture is not ready yet; play the probe and try again") }
    error = nil
    restored = false
    retainedPreview = preview
    starting = true
    controller.startPictureInPicture()
  }

  func stop() { controller?.stopPictureInPicture() }
  var busy: Bool { starting || (controller?.isPictureInPictureActive ?? false) }
  var state: [String: Any] {
    return ["supported": AVPictureInPictureController.isPictureInPictureSupported(), "possible": controller?.isPictureInPicturePossible ?? false, "active": controller?.isPictureInPictureActive ?? false, "starting": starting, "error": error as Any? ?? NSNull()]
  }
  private func failure(_ message: String) -> NSError {
    return NSError(domain: "ExpoSummonVlc.FrameProbePiP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    starting = false
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    starting = false
    self.error = error.localizedDescription
    retainedPreview = nil
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    starting = false
    timer?.invalidate()
    timer = nil
    retainedPreview = nil
    if !restored { FrameProbe.queue.async { FrameProbe.current?.setPlaying(false) } }
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restored = preview?.window != nil
    completionHandler(restored)
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    FrameProbe.queue.async {
      FrameProbe.current?.setPlaying(playing)
      DispatchQueue.main.async { self.refresh() }
    }
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    guard duration > 0 else { return .invalid }
    return CMTimeRange(start: .zero, duration: CMTime(value: duration, timescale: 1000))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { paused }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
    let delta = CMTimeGetSeconds(skipInterval)
    guard delta.isFinite else { completion(); return }
    FrameProbe.queue.async {
      if let probe = FrameProbe.current {
        let target = max(0, min(probe.durationMillis(), probe.positionMillis() + Int64(delta * 1000)))
        probe.seek(toMillis: target)
      }
      DispatchQueue.main.async { self.refresh(); completion() }
    }
  }
}

final class FrameProbePreview: ExpoView {
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    backgroundColor = .black
    FrameProbe.displayLayer.videoGravity = .resizeAspect
    layer.addSublayer(FrameProbe.displayLayer)
    FrameProbePiP.shared.preview = self
    FrameProbePiP.shared.prepare()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    FrameProbe.displayLayer.frame = bounds
  }

  deinit {
    if FrameProbe.displayLayer.superlayer === layer { FrameProbe.displayLayer.removeFromSuperlayer() }
  }
}

public class ExpoSummonVlcProbeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ExpoSummonVlcProbe")
    View(FrameProbePreview.self) {}
  }
}

// The session owns the display layer, so LibVLC can replace its video output
// during a playlist transition without replacing the system PiP controller.
private final class SessionPiPDrawable: UIView {
  let displayLayer: AVSampleBufferDisplayLayer
  var disableResizeAnimation = false
  init(displayLayer: AVSampleBufferDisplayLayer) {
    self.displayLayer = displayLayer
    super.init(frame: .zero)
    backgroundColor = .black
    layer.addSublayer(displayLayer)
  }
  required init?(coder: NSCoder) { return nil }
  override func layoutSubviews() {
    super.layoutSubviews()
    if disableResizeAnimation {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      displayLayer.frame = bounds
      CATransaction.commit()
    } else {
      displayLayer.frame = bounds
    }
  }
}

private final class SessionPiP: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  static let shared = SessionPiP()
  private weak var session: PlayerSession?
  private var drawable: SessionPiPDrawable?
  private var controller: AVPictureInPictureController?
  private var retainedSession: PlayerSession?
  private var retainedView: PlayerView?
  private var starting = false
  private var stopRequested = false
  private var restored = false
  private var releaseCompletion: (() -> Void)?
  private var lastError: String?
  private var timebase: CMTimebase?
  private var clockItem: Int?
  private var clockPlaying: Bool?
  private var syncOnNextClock = false

  func owns(_ candidate: PlayerSession) -> Bool { retainedSession === candidate }
  func prepare(_ candidate: PlayerSession) {
    guard session !== candidate, !owns(candidate), retainedSession == nil, !starting else { return }
    detachCurrent()
    let view = SessionPiPDrawable(displayLayer: candidate.frames.displayLayer)
    view.isUserInteractionEnabled = false
    drawable = view
    session = candidate
    var base: CMTimebase?
    CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base)
    timebase = base
    candidate.frames.displayLayer.controlTimebase = base
    if let base { CMTimebaseSetRate(base, rate: 0) }
    if AVPictureInPictureController.isPictureInPictureSupported() {
      let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: candidate.frames.displayLayer, playbackDelegate: self)
      let pip = AVPictureInPictureController(contentSource: source)
      pip.delegate = self
      controller = pip
    }
    candidate.output?.installDrawable(view)
  }
  func attach(_ candidate: PlayerSession, to view: PlayerView) {
    prepare(candidate)
    if session === candidate, let drawable {
      view.setPictureInPictureActive(owns(candidate))
      view.installDrawable(drawable)
    }
  }
  func detach(_ candidate: PlayerSession) {
    guard session === candidate, !owns(candidate) else { return }
    detachCurrent()
  }
  private func detachCurrent() {
    controller?.delegate = nil
    controller = nil
    drawable?.displayLayer.removeFromSuperlayer()
    drawable?.removeFromSuperview()
    drawable = nil
    timebase = nil
    clockItem = nil
    clockPlaying = nil
    syncOnNextClock = false
    session = nil
  }
  func playbackChanged(_ candidate: PlayerSession, force: Bool = false) {
    DispatchQueue.main.async { [weak self, weak candidate] in
      guard let self, let candidate, self.session === candidate, !candidate.releaseInProgress else { return }
      let playing = candidate.player.isPlaying
      let itemChanged = self.clockItem != candidate.currentIndex
      let shouldSync = force || itemChanged || self.clockPlaying != playing
      if itemChanged { self.syncOnNextClock = true }
      self.clockItem = candidate.currentIndex
      self.clockPlaying = playing
      guard shouldSync else { return }
      if let base = self.timebase {
        CMTimebaseSetTime(base, time: CMTime(value: Int64(max(0, candidate.player.positionMillis)), timescale: 1000))
        CMTimebaseSetRate(base, rate: playing ? candidate.playbackRate : 0)
      }
      self.controller?.invalidatePlaybackState()
    }
  }
  func clockChanged(_ candidate: PlayerSession) {
    guard session === candidate, syncOnNextClock else { return }
    syncOnNextClock = false
    playbackChanged(candidate, force: true)
  }
  func durationChanged(_ candidate: PlayerSession) {
    DispatchQueue.main.async { [weak self, weak candidate] in
      guard let self, let candidate, self.session === candidate, !candidate.releaseInProgress else { return }
      self.controller?.invalidatePlaybackState()
    }
  }
  func state(for candidate: PlayerSession) -> [String: Any] {
    ["supported": AVPictureInPictureController.isPictureInPictureSupported(),
     "active": session === candidate && (controller?.isPictureInPictureActive ?? false),
     "reason": session === candidate ? (lastError as Any? ?? NSNull()) : NSNull(),
     "eventsSupported": true, "stopSupported": AVPictureInPictureController.isPictureInPictureSupported()]
  }
  func start(_ candidate: PlayerSession) throws {
    guard AVPictureInPictureController.isPictureInPictureSupported() else { throw failure("Picture in Picture is unsupported") }
    guard retainedSession == nil || retainedSession === candidate else { throw failure("Another session is using Picture in Picture") }
    prepare(candidate)
    guard let view = candidate.output, view.window != nil else { throw failure("Attach the player view before starting Picture in Picture") }
    guard let controller, controller.isPictureInPicturePossible else { throw failure("Picture in Picture is not ready yet; wait for video and try again") }
    guard !controller.isPictureInPictureActive && !starting else { return }
    try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try AVAudioSession.sharedInstance().setActive(true)
    lastError = nil
    restored = false
    retainedSession = candidate
    candidate.pipGeneration += 1
    retainedView = view
    starting = true
    stopRequested = false
    view.setPictureInPictureActive(true)
    playbackChanged(candidate, force: true)
    controller.startPictureInPicture()
  }
  @discardableResult
  func stop(_ candidate: PlayerSession) throws -> Bool {
    guard retainedSession == nil || retainedSession === candidate else { throw failure("Another session is using Picture in Picture") }
    guard session === candidate else { return false }
    guard let controller else { return false }
    restored = candidate.output?.window != nil && UIApplication.shared.applicationState == .active
    if starting { stopRequested = true; return true }
    guard controller.isPictureInPictureActive else { return false }
    controller.stopPictureInPicture()
    return true
  }
  func stopDiagnostic(_ candidate: PlayerSession) -> String {
    let appState = UIApplication.shared.applicationState.rawValue
    return "sessionMatches=\(session === candidate) retained=\(retainedSession === candidate) controller=\(controller != nil) starting=\(starting) active=\(controller?.isPictureInPictureActive == true) suspended=\(controller?.isPictureInPictureSuspended == true) appState=\(appState)"
  }
  private func failure(_ message: String) -> NSError {
    NSError(domain: "ExpoSummonVlc.SessionPiP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    starting = false
    session?.onPiPChange?(true, nil)
    if releaseCompletion != nil || stopRequested { stopRequested = false; pictureInPictureController.stopPictureInPicture() }
  }
  func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    session?.onPiPWillStop?()
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    guard controller === pictureInPictureController else { return }
    starting = false
    stopRequested = false
    lastError = error.localizedDescription
    session?.pipGeneration += 1
    session?.onPiPChange?(false, error.localizedDescription)
    session?.output?.setPictureInPictureActive(false)
    if releaseCompletion != nil { finishRelease() }
    else { retainedSession = nil; retainedView = nil }
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    guard controller === pictureInPictureController else { return }
    starting = false
    stopRequested = false
    session?.pipGeneration += 1
    session?.onPiPChange?(false, nil)
    if releaseCompletion != nil { finishRelease(); return }
    let previous = retainedSession
    previous?.output?.setPictureInPictureActive(false)
    retainedSession = nil
    retainedView = nil
    if !restored { previous?.setPlaying(false) }
    if let previous, previous.output == nil { detach(previous) }
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restored = session?.output?.window != nil
    completionHandler(restored)
  }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
    session?.setPlaying(playing)
    if let session { playbackChanged(session) }
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
    let duration = max(session?.lastDuration ?? 0, session?.player.durationMillis ?? 0)
    guard duration > 0 else { return .invalid }
    return CMTimeRange(start: .zero, duration: CMTime(value: Int64(duration), timescale: 1000))
  }
  func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool { session?.player.isPlaying != true }
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion: @escaping () -> Void) {
    guard let session, !session.releaseInProgress else { completion(); return }
    let seconds = CMTimeGetSeconds(skipInterval)
    guard seconds.isFinite else { completion(); return }
    let offset = Int64(seconds * 1000)
    let position = Int64(max(0, session.player.positionMillis))
    let length = Int64(max(session.lastDuration, session.player.durationMillis))
    if offset > 0, length > 0, position + offset >= length, session.player.isPlaying, session.repeatMode == "one" || session.canNext {
      do { if try session.next(automatic: true) { completion(); return } }
      catch { NSLog("ExpoSummonVlc: PiP playlist advance failed: %@", error.localizedDescription) }
    }
    if !session.player.jump(withOffset: Int32(clamping: offset), completion: completion) { completion() }
  }
  func releaseAfterPiP(_ candidate: PlayerSession, completion: @escaping () -> Void, timeout: @escaping () -> Void) {
    guard owns(candidate) else { detach(candidate); completion(); return }
    releaseCompletion = completion
    if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
    else if !starting { finishRelease(); return }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak candidate] in
      guard let self, let candidate, self.retainedSession === candidate, self.releaseCompletion != nil else { return }
      self.releaseCompletion = nil
      timeout()
    }
  }
  private func finishRelease() {
    let completion = releaseCompletion
    releaseCompletion = nil
    retainedSession = nil
    retainedView = nil
    detachCurrent()
    completion?()
  }
  func shutdown() {
    controller?.stopPictureInPicture()
    releaseCompletion = nil
    retainedSession = nil
    retainedView = nil
    detachCurrent()
  }
}

final class PlayerView: ExpoView {
  private let videoView = UIView()
  private var sessionId: String?
  private var videoGravity: AVLayerVideoGravity = .resizeAspect
  private var pictureInPictureActive = false
  private var disableResizeAnimation = false
  required init(appContext: AppContext? = nil) {
    super.init(appContext: appContext)
    clipsToBounds = true
    videoView.backgroundColor = .black
    addSubview(videoView)
  }
  override func layoutSubviews() {
    super.layoutSubviews()
    videoView.frame = bounds
    videoView.subviews.forEach { $0.frame = videoView.bounds }
  }
  fileprivate func installDrawable(_ drawable: UIView) {
    if drawable.superview !== videoView { videoView.addSubview(drawable) }
    drawable.frame = videoView.bounds
    drawable.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    if let drawable = drawable as? SessionPiPDrawable {
      drawable.disableResizeAnimation = disableResizeAnimation
      drawable.displayLayer.videoGravity = pictureInPictureActive ? .resizeAspect : videoGravity
    }
  }
  func setDisableResizeAnimation(_ disabled: Bool) {
    disableResizeAnimation = disabled
    videoView.subviews.compactMap { $0 as? SessionPiPDrawable }.forEach { $0.disableResizeAnimation = disabled }
  }
  func setPictureInPictureActive(_ active: Bool) {
    pictureInPictureActive = active
    updateVideoGravity()
  }
  func setResizeMode(_ mode: String?) {
    switch mode {
    case "cover": videoGravity = .resizeAspectFill
    case "fill": videoGravity = .resize
    default: videoGravity = .resizeAspect
    }
    updateVideoGravity()
  }
  private func updateVideoGravity() {
    if let id = sessionId, let session = Sessions.items[id] {
      session.frames.displayLayer.videoGravity = pictureInPictureActive ? .resizeAspect : videoGravity
    }
  }
  func attach(_ id: String?) {
    if sessionId == id { return }
    detach()
    guard let id, let session = Sessions.items[id], session.output == nil else { return }
    sessionId = id
    session.output = self
    SessionPiP.shared.attach(session, to: self)
  }
  private func detach() {
    if let id = sessionId, let session = Sessions.items[id], session.output === self {
      session.output = nil
      SessionPiP.shared.detach(session)
    }
    sessionId = nil
  }
  deinit { detach() }
}

public class ExpoSummonVlcModule: Module {
  private func playlistItems(_ values: [[String: String]]) throws -> [PlaylistItem] {
    let items = try values.map { try PlaylistItem($0) }
    guard Set(items.map(\.id)).count == items.count else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 3, userInfo: [NSLocalizedDescriptionKey: "Playlist item IDs must be unique"]) }
    return items
  }
  private func subtitleStyleOptions(_ style: [String: Double]) throws -> [String] {
    let limits: [String: ClosedRange<Double>] = ["fontScale": 0.5...3, "backgroundColor": 0...16777215, "backgroundOpacity": 0...255, "outlineColor": 0...16777215, "outlineWidth": 0...5, "bottomMargin": 0...500]
    guard Set(style.keys).subtracting(["alignment", "textColor"]) == Set(limits.keys),
          style["textColor"].map({ $0.isFinite && (0...16777215).contains($0) && $0.rounded() == $0 }) ?? true,
          style["alignment"].map({ [-1.0, 0.0, 1.0, 2.0].contains($0) }) ?? true,
          limits.allSatisfy({ key, range in
      guard let value = style[key], value.isFinite, range.contains(value) else { return false }
      return key == "fontScale" || value.rounded() == value
    }) else { throw NSError(domain: "ExpoSummonVlc.Subtitles", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid subtitle style"] ) }
    var options = ["--sub-text-scale=\(Int((style["fontScale"]! * 100).rounded()))",
            "--freetype-background-color=\(Int(style["backgroundColor"]!))",
            "--freetype-background-opacity=\(Int(style["backgroundOpacity"]!))",
            "--freetype-outline-color=\(Int(style["outlineColor"]!))",
            "--freetype-outline-opacity=255",
            "--freetype-outline-thickness=\(Int(style["outlineWidth"]!))",
            "--sub-margin=\(Int(style["bottomMargin"]!))"]
    if let color = style["textColor"] { options.append("--freetype-color=\(Int(color))") }
    if let alignment = style["alignment"] { options.append("--subsdec-align=\(Int(alignment))") }
    return options
  }
  private func createPlayerSession(options: [String]?) throws -> String {
    guard Sessions.pendingCleanup == 0 else {
      throw NSError(domain: "ExpoSummonVlc", code: 16, userInfo: [NSLocalizedDescriptionKey: "A previous VLC player is still being released. Try again after cleanup finishes."])
    }
    let id = UUID().uuidString
    guard let session = PlayerSession(videoOutput: ESVLCSessionOutput(options: options)) else {
      throw NSError(domain: "ExpoSummonVlc", code: 12, userInfo: [NSLocalizedDescriptionKey: "Could not create the VLC video output"])
    }
    session.onStateChange = { [weak self, weak session] in
      DispatchQueue.main.async {
        guard let session, Sessions.items[id] === session, !session.releaseInProgress else { return }
        let state = session.state
        let key = "\(session.currentIndex):\(session.currentItemID ?? ""):\(state)"
        if key != session.lastReportedState {
          session.lastReportedState = key
          session.eventSequence += 1
          let identity: [String: Any] = ["sessionId": id, "currentIndex": session.currentIndex, "currentItemId": session.currentItemID as Any? ?? NSNull(), "sequence": session.eventSequence]
          var event = identity
          event["state"] = state
          self?.sendEvent("onPlaybackStateChange", event)
          if let failure = session.playbackError {
            var errorEvent = identity
            failure.forEach { errorEvent[$0.key] = $0.value }
            self?.sendEvent("onPlaybackError", errorEvent)
          }
        }
        session.handlePlaybackState(state)
        if state == "error" { session.handlePlaybackFailure() }
        SessionPiP.shared.playbackChanged(session)
        ControlCenter.shared.refresh(session)
      }
    }
    session.onTracksChange = { [weak self, weak session] in
      guard let session, Sessions.items[id] === session, !session.releaseInProgress else { return }
      self?.sendEvent("onTracksChanged", ["sessionId": id, "revision": session.trackRevision])
    }
    session.onProgress = { [weak self, weak session] in
      guard let session, Sessions.items[id] === session, !session.releaseInProgress else { return }
      self?.sendEvent("onPlaybackProgress", ["sessionId": id, "currentIndex": session.currentIndex,
        "currentItemId": session.currentItemID as Any? ?? NSNull(), "mediaRevision": session.trackRevision,
        "sequence": session.progressSequence, "positionMillis": max(0, session.player.positionMillis),
        "durationMillis": max(0, max(session.lastDuration, session.player.durationMillis))])
    }
    session.onPiPChange = { [weak self, weak session] active, reason in
      guard let session, Sessions.items[id] === session else { return }
      var event = SessionPiP.shared.state(for: session)
      event["sessionId"] = id
      event["active"] = active
      event["reason"] = reason as Any? ?? NSNull()
      self?.sendEvent("onPictureInPictureStateChange", event)
    }
    session.onPiPWillStop = { [weak self, weak session] in
      guard let session, Sessions.items[id] === session, session.pipExitTestGeneration == session.pipGeneration else { return }
      self?.sendEvent("onPictureInPictureExitTest", ["sessionId": id, "stage": "will_stop", "message": SessionPiP.shared.stopDiagnostic(session)])
    }
    Sessions.items[id] = session
    session.startProgressUpdates()
    return id
  }
  public func definition() -> ModuleDefinition {
    Name("ExpoSummonVlc")
    Events("onPlaybackStateChange", "onPlaybackProgress", "onPlaybackError", "onTracksChanged", "onPictureInPictureStateChange", "onPictureInPictureExitTest")

    AsyncFunction("startFrameProbe") { (uri: String) in
      guard FrameProbe.current == nil else {
        throw NSError(domain: "ExpoSummonVlc", code: 8, userInfo: [NSLocalizedDescriptionKey: "A frame probe is already running"])
      }
      guard let url = URL(string: uri), url.isFileURL else {
        throw NSError(domain: "ExpoSummonVlc", code: 9, userInfo: [NSLocalizedDescriptionKey: "Frame probe requires a local file URL"])
      }
      let probe = ESVLCFrameProbe(displayLayer: FrameProbe.displayLayer)
      if let message = probe.start(url: url) {
        throw NSError(domain: "ExpoSummonVlc", code: 10, userInfo: [NSLocalizedDescriptionKey: message])
      }
      FrameProbe.current = probe
    }.runOnQueue(FrameProbe.queue)

    AsyncFunction("getFrameProbeStatus") { () -> [String: Any] in
      return ["running": FrameProbe.current != nil, "frames": FrameProbe.current?.frameCount() ?? 0]
    }.runOnQueue(FrameProbe.queue)

    AsyncFunction("stopFrameProbe") { (promise: Promise) in
      guard !FrameProbePiP.shared.busy else {
        promise.reject("ERR_PROBE_PIP_ACTIVE", "Stop frame probe PiP before stopping the probe")
        return
      }
      FrameProbe.queue.async {
        FrameProbe.current?.stop()
        FrameProbe.current = nil
        promise.resolve(nil)
      }
    }.runOnQueue(.main)

    AsyncFunction("setFrameProbePlaying") { (playing: Bool) in
      guard let probe = FrameProbe.current else { throw NSError(domain: "ExpoSummonVlc", code: 11, userInfo: [NSLocalizedDescriptionKey: "Start the frame probe first"]) }
      probe.setPlaying(playing)
      DispatchQueue.main.async { FrameProbePiP.shared.refresh() }
    }.runOnQueue(FrameProbe.queue)

    AsyncFunction("getFrameProbePictureInPictureState") { () -> [String: Any] in
      return FrameProbePiP.shared.state
    }.runOnQueue(.main)

    AsyncFunction("startFrameProbePictureInPicture") { try FrameProbePiP.shared.start() }.runOnQueue(.main)
    AsyncFunction("stopFrameProbePictureInPicture") { FrameProbePiP.shared.stop() }.runOnQueue(.main)

    AsyncFunction("inspectMedia") { (id: String, uri: String, timeout: Int, promise: Promise) in
      MediaAnalysis.shared.inspect(id: id, uri: uri, timeout: timeout, promise: promise)
    }.runOnQueue(.main)
    AsyncFunction("generateThumbnail") { (id: String, uri: String, position: Double, timeout: Int, promise: Promise) in
      MediaAnalysis.shared.thumbnail(id: id, uri: uri, position: position, timeout: timeout, promise: promise)
    }.runOnQueue(.main)
    AsyncFunction("cancelMediaJob") { (id: String) -> Bool in MediaAnalysis.shared.cancel(id: id) }.runOnQueue(.main)

    AsyncFunction("createSession") { [self] () -> String in
      try createPlayerSession(options: nil)
    }.runOnQueue(.main)

    AsyncFunction("createSessionWithSubtitleStyle") { [self] (style: [String: Double]) -> String in
      try createPlayerSession(options: subtitleStyleOptions(style))
    }.runOnQueue(.main)

    AsyncFunction("setSubtitleFontScale") { (id: String, scale: Double) in
      guard scale.isFinite, (0.5...3.0).contains(scale) else { throw NSError(domain: "ExpoSummonVlc.Subtitles", code: 1, userInfo: [NSLocalizedDescriptionKey: "Font scale must be between 0.5 and 3.0"]) }
      try Sessions.get(id).videoOutput.setSubtitleFontScale(Float(scale))
    }.runOnQueue(.main)
    AsyncFunction("getSubtitleStyleCapabilities") { () -> [String: Any] in
      ["creationStyle": true, "liveFontScale": true]
    }.runOnQueue(.main)

    AsyncFunction("load") { (id: String, uri: String) in
      guard let url = URL(string: uri), url.scheme != nil else {
        throw NSError(domain: "ExpoSummonVlc", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid media URI"])
      }
      let session = try Sessions.get(id)
      session.cancelAudioResume()
      session.trackRevision = UUID().uuidString
      session.cancelTransition()
      session.autoAdvanceArmed = false
      session.player.stop()
      session.pendingSeek = nil
      session.lastDuration = 0
      session.clearPlaylist()
      guard let media = VLCMedia(url: url) else {
        throw NSError(domain: "ExpoSummonVlc", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create media"])
      }
      session.videoOutput.setListRepeatMode("off")
      session.videoOutput.setMediaItems([media])
      session.videoOutput.loadMedia(media)
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)

    AsyncFunction("setPlaylist") { (id: String, uris: [String]) in
      guard !uris.isEmpty else { throw NSError(domain: "ExpoSummonVlc", code: 3, userInfo: [NSLocalizedDescriptionKey: "Playlist cannot be empty"]) }
      let urls = uris.compactMap { URL(string: $0) }
      guard urls.count == uris.count, urls.allSatisfy({ $0.scheme != nil }) else {
        throw NSError(domain: "ExpoSummonVlc", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid media URI"])
      }
      let session = try Sessions.get(id)
      session.preparePlaylistReplacement()
      try session.setPlaylist(urls)
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)

    AsyncFunction("selectPlaylistItem") { (id: String, index: Int) in
      try Sessions.get(id).select(index)
    }.runOnQueue(.main)

    AsyncFunction("setPlaylistItems") { [self] (id: String, values: [[String: String]]) in
      let items = try playlistItems(values)
      guard !items.isEmpty else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 1, userInfo: [NSLocalizedDescriptionKey: "Playlist cannot be empty"]) }
      let session = try Sessions.get(id)
      session.preparePlaylistReplacement()
      try session.setPlaylist(items.map(\.url), items: items)
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)
    AsyncFunction("getPlaylist") { (id: String) -> [[String: String]] in
      try Sessions.get(id).playlistItems.map(\.dictionary)
    }.runOnQueue(.main)
    AsyncFunction("getCurrentItem") { (id: String) -> [String: String]? in
      let session = try Sessions.get(id)
      return session.playlistItems.indices.contains(session.currentIndex) ? session.playlistItems[session.currentIndex].dictionary : nil
    }.runOnQueue(.main)
    AsyncFunction("insertItem") { [self] (id: String, index: Int, value: [String: String]) in
      let session = try Sessions.get(id)
      guard index >= 0 && index <= session.playlistItems.count else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist index"]) }
      var values = session.playlistItems.map(\.dictionary)
      values.insert(value, at: index)
      try session.editPlaylist(playlistItems(values))
    }.runOnQueue(.main)
    AsyncFunction("addItem") { [self] (id: String, value: [String: String]) in
      let session = try Sessions.get(id)
      try session.editPlaylist(playlistItems(session.playlistItems.map(\.dictionary) + [value]))
    }.runOnQueue(.main)
    AsyncFunction("removeItem") { (id: String, itemID: String) in
      let session = try Sessions.get(id)
      guard session.playlistItems.contains(where: { $0.id == itemID }) else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 5, userInfo: [NSLocalizedDescriptionKey: "Playlist item does not exist"]) }
      try session.editPlaylist(session.playlistItems.filter { $0.id != itemID })
    }.runOnQueue(.main)
    AsyncFunction("moveItem") { (id: String, from: Int, to: Int) in
      let session = try Sessions.get(id)
      var items = session.playlistItems
      guard items.indices.contains(from), items.indices.contains(to) else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid playlist index"]) }
      let item = items.remove(at: from)
      items.insert(item, at: to)
      try session.editPlaylist(items)
    }.runOnQueue(.main)
    AsyncFunction("clearPlaylist") { (id: String) in try Sessions.get(id).editPlaylist([]) }.runOnQueue(.main)
    AsyncFunction("selectItem") { (id: String, itemID: String) in
      let session = try Sessions.get(id)
      guard let index = session.playlistItems.firstIndex(where: { $0.id == itemID }) else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 5, userInfo: [NSLocalizedDescriptionKey: "Playlist item does not exist"]) }
      try session.select(index)
    }.runOnQueue(.main)

    AsyncFunction("next") { (id: String) in
      let session = try Sessions.get(id)
      guard try session.next() else { throw NSError(domain: "ExpoSummonVlc", code: 4, userInfo: [NSLocalizedDescriptionKey: "No playlist item in that direction"]) }
    }.runOnQueue(.main)

    AsyncFunction("previous") { (id: String) in
      let session = try Sessions.get(id)
      guard try session.previous() else { throw NSError(domain: "ExpoSummonVlc", code: 4, userInfo: [NSLocalizedDescriptionKey: "No playlist item in that direction"]) }
    }.runOnQueue(.main)

    AsyncFunction("setRepeatMode") { (id: String, mode: String) in
      guard ["off", "one", "all"].contains(mode) else { throw NSError(domain: "ExpoSummonVlc", code: 14, userInfo: [NSLocalizedDescriptionKey: "Invalid repeat mode"]) }
      let session = try Sessions.get(id)
      session.repeatMode = mode
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)
    AsyncFunction("setShuffleEnabled") { (id: String, enabled: Bool) in
      let session = try Sessions.get(id)
      session.setShuffle(enabled)
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)
    AsyncFunction("setTransitionTimeout") { (id: String, timeoutMillis: Double) in
      guard timeoutMillis.isFinite, timeoutMillis >= 1000 else {
        throw NSError(domain: "ExpoSummonVlc.Transition", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transition timeout must be at least 1000 milliseconds"])
      }
      try Sessions.get(id).transitionTimeoutMillis = timeoutMillis
    }.runOnQueue(.main)

    AsyncFunction("setFailurePolicy") { (id: String, policy: String) in
      guard policy == "stop" || policy == "skip" else { throw NSError(domain: "ExpoSummonVlc.Playlist", code: 6, userInfo: [NSLocalizedDescriptionKey: "Invalid playback failure policy"]) }
      let session = try Sessions.get(id)
      session.failurePolicy = policy
    }.runOnQueue(.main)
    AsyncFunction("setControlCenterEnabled") { (id: String, enabled: Bool) in
      try ControlCenter.shared.setEnabled(enabled, session: Sessions.get(id))
    }.runOnQueue(.main)

    AsyncFunction("setBackgroundPlaybackEnabled") { (id: String, enabled: Bool) in
      _ = try Sessions.get(id)
      if enabled { throw NSError(domain: "ExpoSummonVlc", code: 24, userInfo: [NSLocalizedDescriptionKey: "Android background playback service is not available on iOS"]) }
    }.runOnQueue(.main)
    AsyncFunction("getBackgroundSessionId") { () -> String? in nil }.runOnQueue(.main)

    AsyncFunction("setPlaybackRate") { (id: String, rate: Double) in
      guard rate.isFinite, (0.25...4).contains(rate) else { throw NSError(domain: "ExpoSummonVlc", code: 18, userInfo: [NSLocalizedDescriptionKey: "Playback rate must be between 0.25 and 4"]) }
      let session = try Sessions.get(id)
      guard session.player.setPlaybackRate(Float(rate)) else { throw NSError(domain: "ExpoSummonVlc", code: 19, userInfo: [NSLocalizedDescriptionKey: "Playback rate could not be set"]) }
      session.playbackRate = rate
      SessionPiP.shared.playbackChanged(session, force: true)
      ControlCenter.shared.refresh(session)
    }.runOnQueue(.main)
    AsyncFunction("setVolume") { (id: String, volume: Double) in
      guard volume.isFinite, (0...1).contains(volume) else { throw NSError(domain: "ExpoSummonVlc", code: 20, userInfo: [NSLocalizedDescriptionKey: "Volume must be between 0 and 1"]) }
      let session = try Sessions.get(id)
      let value = Int((volume * 100).rounded())
      guard session.muted || session.player.setSoftwareVolume(Int32(value)) else { throw NSError(domain: "ExpoSummonVlc", code: 21, userInfo: [NSLocalizedDescriptionKey: "Volume could not be set"]) }
      session.volume = value
    }.runOnQueue(.main)
    AsyncFunction("setMuted") { (id: String, muted: Bool) in
      let session = try Sessions.get(id)
      guard session.player.setSoftwareVolume(Int32(muted ? 0 : session.volume)) else { throw NSError(domain: "ExpoSummonVlc", code: 21, userInfo: [NSLocalizedDescriptionKey: "Volume could not be set"]) }
      session.muted = muted
    }.runOnQueue(.main)
    AsyncFunction("setAudioDelay") { (id: String, delay: Double) in
      guard delay.isFinite, (-10000...10000).contains(delay), delay.rounded() == delay else { throw NSError(domain: "ExpoSummonVlc", code: 22, userInfo: [NSLocalizedDescriptionKey: "Audio delay must be an integer between -10000 and 10000 milliseconds"]) }
      let session = try Sessions.get(id)
      guard session.state == "playing" || session.state == "paused", !session.isTransitioning else { throw NSError(domain: "ExpoSummonVlc", code: 23, userInfo: [NSLocalizedDescriptionKey: "Audio delay requires playing or paused media"]) }
      let value = Int64(delay)
      guard session.player.setAudioDelay(millis: value) else { throw NSError(domain: "ExpoSummonVlc", code: 24, userInfo: [NSLocalizedDescriptionKey: "Audio delay could not be set"]) }
      session.audioDelayMillis = value
      session.audioDelayApplied = true
    }.runOnQueue(.main)

    AsyncFunction("getPlaybackStatus") { (id: String) -> [String: Any] in
      let session = try Sessions.get(id)
      session.applyPendingSeek()
      let duration = session.player.durationMillis
      if !session.isTransitioning && duration > 0 { session.lastDuration = duration }
      return ["state": session.state, "currentIndex": session.currentIndex,
              "currentItemId": session.currentItemID as Any? ?? NSNull(), "eventSequence": session.eventSequence,
              "mediaRevision": session.trackRevision, "progressSequence": session.progressSequence,
              "error": session.playbackError as Any? ?? NSNull(),
              "positionMillis": max(0, session.player.positionMillis),
              "durationMillis": max(0, session.lastDuration),
              "playbackRate": session.playbackRate, "volume": Double(session.volume) / 100, "muted": session.muted,
              "audioDelayMillis": session.audioDelayMillis, "audioDelayApplied": session.audioDelayApplied,
              "isSeekable": session.videoOutput.nativeIsSeekable() || (session.state == "ended" && session.lastDuration > 0),
              "repeatMode": session.repeatMode, "shuffleEnabled": session.shuffleEnabled,
              "failurePolicy": session.failurePolicy,
              "canNext": session.canNext, "canPrevious": session.canPrevious]
    }.runOnQueue(.main)

    AsyncFunction("getTracks") { (id: String) -> [String: Any] in
      let session = try Sessions.get(id)
      guard !session.isTransitioning, session.state == "playing" || session.state == "paused" else { throw NSError(domain: "ExpoSummonVlc.Tracks", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tracks are unavailable until media is playing or paused"]) }
      guard let audio = session.videoOutput.tracks(for: "audio"), let subtitles = session.videoOutput.tracks(for: "subtitle") else {
        throw NSError(domain: "ExpoSummonVlc.Tracks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Tracks are not available yet"])
      }
      return ["revision": session.trackRevision, "currentIndex": session.currentIndex, "audio": audio, "subtitles": subtitles]
    }.runOnQueue(.main)

    AsyncFunction("selectTrack") { (id: String, type: String, identifier: String?, revision: String) in
      let session = try Sessions.get(id)
      guard type == "audio" || type == "subtitle", identifier != nil || type == "subtitle" else { throw NSError(domain: "ExpoSummonVlc.Tracks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid track type or identifier"]) }
      guard !session.isTransitioning, session.state == "playing" || session.state == "paused", revision == session.trackRevision else { throw NSError(domain: "ExpoSummonVlc.Tracks", code: 4, userInfo: [NSLocalizedDescriptionKey: "Track list is stale; refresh it first"]) }
      guard session.videoOutput.selectTrack(for: type, identifier: identifier) else { throw NSError(domain: "ExpoSummonVlc.Tracks", code: 5, userInfo: [NSLocalizedDescriptionKey: "Track is unavailable"]) }
    }.runOnQueue(.main)

    AsyncFunction("seekTo") { (id: String, millis: Double, options: [String: String]?) in
      let precision = options?["precision"] ?? "fast"
      guard precision == "fast" || precision == "precise" else {
        throw NSError(domain: "ExpoSummonVlc.Seek", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid seek precision"])
      }
      let session = try Sessions.get(id)
      try session.seek(to: millis, fast: precision == "fast")
    }.runOnQueue(.main)

    AsyncFunction("getPictureInPictureState") { (id: String) -> [String: Any] in
      let session = try Sessions.get(id)
      return SessionPiP.shared.state(for: session)
    }.runOnQueue(.main)

    AsyncFunction("startPictureInPicture") { (id: String) -> Void in
      try SessionPiP.shared.start(try Sessions.get(id))
    }.runOnQueue(.main)

    AsyncFunction("stopPictureInPicture") { (id: String) -> Void in
      _ = try SessionPiP.shared.stop(try Sessions.get(id))
    }.runOnQueue(.main)

    AsyncFunction("startPictureInPictureExitTest") { [weak self] (id: String, delay: Double) in
      guard delay.isFinite, (1000...30000).contains(delay) else { throw NSError(domain: "ExpoSummonVlc.PiP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid test delay"]) }
      let session = try Sessions.get(id)
      try SessionPiP.shared.start(session)
      let generation = session.pipGeneration
      session.pipExitTestGeneration = generation
      DispatchQueue.main.asyncAfter(deadline: .now() + delay / 1000) { [weak self, weak session] in
        guard let session, Sessions.items[id] === session, !session.releaseInProgress, session.pipGeneration == generation else { return }
        do {
          let before = SessionPiP.shared.stopDiagnostic(session)
          let requested = try SessionPiP.shared.stop(session)
          let after = SessionPiP.shared.stopDiagnostic(session)
          self?.sendEvent("onPictureInPictureExitTest", ["sessionId": id, "stage": requested ? "requested" : "not_active", "message": "before: \(before); after: \(after)"])
          guard requested else { return }
          DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak session] in
            guard let session, Sessions.items[id] === session, session.pipGeneration == generation,
                  SessionPiP.shared.state(for: session)["active"] as? Bool == true else { return }
            self?.sendEvent("onPictureInPictureExitTest", ["sessionId": id, "stage": "still_active", "message": "PiP remains active after the exit request."])
          }
        } catch {
          self?.sendEvent("onPictureInPictureExitTest", ["sessionId": id, "stage": "failed", "message": error.localizedDescription])
        }
      }
    }.runOnQueue(.main)

    AsyncFunction("play") { (id: String) in try Sessions.get(id).playFromAPI() }.runOnQueue(.main)
    AsyncFunction("pause") { (id: String) in
      try Sessions.get(id).setPlaying(false)
    }.runOnQueue(.main)
    AsyncFunction("stop") { (id: String) in
      let session = try Sessions.get(id)
      session.cancelAudioResume()
      session.cancelTransition()
      session.autoAdvanceArmed = false
      session.pendingSeek = nil
      session.player.stop()
    }.runOnQueue(.main)
    AsyncFunction("release") { (id: String, promise: Promise) in
      guard let session = Sessions.items[id], !session.releaseInProgress else {
        promise.reject("ERR_SESSION_RELEASE", "Session does not exist or release is already in progress")
        return
      }
      session.releaseInProgress = true
      SessionPiP.shared.releaseAfterPiP(session, completion: {
        ControlCenter.shared.clear(session)
        Sessions.items.removeValue(forKey: id)
        Sessions.pendingCleanup += 1
        let ticket = PlayerReleaseTicket(promise)
        session.release {
          Sessions.pendingCleanup -= 1
          guard !ticket.settled else { return }
          ticket.settled = true
          ticket.promise.resolve(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
          guard !ticket.settled else { return }
          ticket.settled = true
          ticket.promise.reject("ERR_PLAYER_RELEASE_TIMEOUT", "Native player cleanup is still running; try creating a session again after it finishes")
        }
      }, timeout: {
        session.releaseInProgress = false
        promise.reject("ERR_PIP_STOP_TIMEOUT", "Picture in Picture did not stop; try closing it and releasing again")
      })
    }.runOnQueue(.main)

    View(PlayerView.self) {
      Prop("sessionId") { (view: PlayerView, id: String?) in view.attach(id) }
      Prop("resizeMode") { (view: PlayerView, mode: String?) in view.setResizeMode(mode) }
      Prop("disableResizeAnimation") { (view: PlayerView, disabled: Bool?) in view.setDisableResizeAnimation(disabled ?? false) }
    }

    OnDestroy {
      FrameProbe.queue.async {
        FrameProbe.current?.stop()
        FrameProbe.current = nil
      }
      let cleanup = {
        MediaAnalysis.shared.shutdown()
        SessionPiP.shared.shutdown()
        ControlCenter.shared.clear()
        Sessions.items.values.forEach { $0.release() }
        Sessions.items.removeAll()
      }
      if Thread.isMainThread { cleanup() } else { DispatchQueue.main.sync(execute: cleanup) }
    }
  }
}
#else
public class ExpoSummonVlcModule: Module {
  public func definition() -> ModuleDefinition { Name("ExpoSummonVlc") }
}
#endif
