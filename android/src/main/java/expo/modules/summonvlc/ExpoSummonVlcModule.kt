package expo.modules.summonvlc

import android.content.Context
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.res.Configuration
import android.app.Activity
import android.app.PendingIntent
import android.app.PictureInPictureParams
import android.app.RemoteAction
import android.content.pm.PackageManager
import android.graphics.Rect
import android.graphics.Color
import android.graphics.drawable.Icon
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.util.Rational
import android.view.View
import android.widget.FrameLayout
import androidx.core.util.Consumer
import android.widget.LinearLayout
import expo.modules.kotlin.AppContext
import expo.modules.kotlin.Promise
import expo.modules.kotlin.functions.Queues
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.views.ExpoView
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.MediaPlayer
import org.videolan.libvlc.interfaces.IMedia
import org.videolan.libvlc.util.VLCVideoLayout
import java.util.UUID
import java.lang.ref.WeakReference

private fun unsupportedFrameProbe(): Unit {
  throw UnsupportedOperationException("The frame probe is only available on iOS")
}

private fun unsupportedTransitionTimeout(): Unit {
  throw UnsupportedOperationException("Transition timeout is available on iOS only")
}

private fun unsupportedLiveSubtitleScale(): Unit {
  throw UnsupportedOperationException("Changing subtitle size during playback requires VLC 4; create a styled session instead")
}

private data class PlaylistItem(val id: String, val uri: Uri, val title: String?) {
  fun toMap(): Map<String, String> = buildMap {
    put("id", id)
    put("uri", uri.toString())
    if (title != null) put("title", title)
  }
  companion object {
    fun parse(value: Map<String, String>): PlaylistItem {
      require(value.keys.all { it in setOf("id", "uri", "title") }) { "Invalid playlist item" }
      val id = value["id"] ?: throw IllegalArgumentException("Invalid playlist item")
      val uri = Uri.parse(value["uri"] ?: throw IllegalArgumentException("Invalid playlist item"))
      require(id.isNotBlank() && !uri.scheme.isNullOrBlank()) { "Invalid playlist item" }
      return PlaylistItem(id, uri, value["title"])
    }
  }
}

private class PlayerSession(context: Context, options: List<String>? = null) {
  private val appContext = context.applicationContext
  private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
  val libVlc = if (options == null) LibVLC(appContext) else LibVLC(appContext, options.toMutableList())
  val player = MediaPlayer(libVlc)
  private var focusGranted = false
  private var focusRequested = false
  private var focusInterrupted = false
  private var resumeOnFocus = false
  private var wantsPlayback = false
  private var released = false
  private val focusListener = AudioManager.OnAudioFocusChangeListener { change ->
    if (!released && focusRequested) when (change) {
      AudioManager.AUDIOFOCUS_LOSS -> {
        focusGranted = false
        focusInterrupted = false
        resumeOnFocus = false
        wantsPlayback = false
        if (player.isPlaying) player.pause()
        abandonAudioFocus()
      }
      AudioManager.AUDIOFOCUS_LOSS_TRANSIENT, AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
        focusGranted = false
        focusInterrupted = true
        resumeOnFocus = wantsPlayback && (player.isPlaying || state() == "preparing" || state() == "buffering")
        if (player.isPlaying) player.pause()
      }
      AudioManager.AUDIOFOCUS_GAIN -> {
        focusGranted = true
        focusInterrupted = false
        val resume = resumeOnFocus && wantsPlayback
        resumeOnFocus = false
        if (resume) player.play()
      }
    }
  }
  private val focusRequest: AudioFocusRequest? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
    AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
      .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_MOVIE).build())
      .setWillPauseWhenDucked(true)
      .setOnAudioFocusChangeListener(focusListener, android.os.Handler(android.os.Looper.getMainLooper()))
      .build()
  } else null
  private val noisyReceiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      if (intent.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) pausePlayback()
    }
  }
  var output: PlayerView? = null
  var playlist: List<Uri> = emptyList()
  var playlistItems: List<PlaylistItem> = emptyList()
  var currentIndex = -1
  var lastReportedState = ""
  var eventSequence = 0L
  var progressSequence = 0L
  var onProgress: (() -> Unit)? = null
  private val progressHandler = android.os.Handler(android.os.Looper.getMainLooper())
  private var lastProgressKey = ""
  private val progressRunnable = object : Runnable {
    override fun run() {
      if (released) return
      if (!transitionPending && (state() == "playing" || state() == "paused") && player.hasMedia()) {
        val position = player.time.coerceAtLeast(0)
        val duration = maxOf(lastDuration, player.length).coerceAtLeast(0)
        val key = "$generation:$currentIndex:$position:$duration"
        if (key != lastProgressKey) {
          lastProgressKey = key
          progressSequence++
          onProgress?.invoke()
        }
      }
      progressHandler.postDelayed(this, 100)
    }
  }
  var onPlaylistEdited: (() -> Unit)? = null
  var lastDuration = 0L
  var pendingSeek: Long? = null
  @Volatile var generation = 0L
  var autoAdvanceArmed = false
  var playbackFailed = false
  var failurePolicy = "stop"
  private val failedItems = mutableSetOf<String>()
  var transitionPending = false
  var playbackRate = 1.0
  var volume = 100
  var muted = false
  var audioDelayMillis = 0L
  var audioDelayApplied = false
  var repeatMode = "off"
  var shuffleEnabled = false
    private set
  private val shuffleRemaining = mutableListOf<Int>()
  private val history = mutableListOf<Int>()
  private var historyIndex = -1
  var pipControls: PictureInPictureControls? = null
  var pipGeneration = 0L
  var videoAspectRatio: Double? = null
  private var lastVideoTrackCheck = 0L

  init {
    // A PiP window can have a different orientation from the host activity.
    player.setUseOrientationFromBounds(true)
    val filter = IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) appContext.registerReceiver(noisyReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
    else appContext.registerReceiver(noisyReceiver, filter)
  }

  fun startProgressUpdates() {
    progressHandler.removeCallbacks(progressRunnable)
    progressHandler.post(progressRunnable)
  }

  private fun requestAudioFocus() {
    check(!focusInterrupted) { "Audio is temporarily interrupted" }
    if (focusGranted) return
    focusRequested = true
    val result = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) audioManager.requestAudioFocus(focusRequest)
      else @Suppress("DEPRECATION") audioManager.requestAudioFocus(focusListener, AudioManager.STREAM_MUSIC, AudioManager.AUDIOFOCUS_GAIN)
    if (result != AudioManager.AUDIOFOCUS_REQUEST_GRANTED) focusRequested = false
    check(result == AudioManager.AUDIOFOCUS_REQUEST_GRANTED) { "Audio focus was not granted" }
    focusGranted = true
  }
  private fun abandonAudioFocus() {
    focusRequested = false
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && focusRequest != null) audioManager.abandonAudioFocusRequest(focusRequest)
    else @Suppress("DEPRECATION") audioManager.abandonAudioFocus(focusListener)
    focusGranted = false
    focusInterrupted = false
  }
  fun playPlayback() {
    requestAudioFocus()
    playbackFailed = false
    resumeOnFocus = false
    wantsPlayback = true
    player.play()
  }
  fun pausePlayback() {
    resumeOnFocus = false
    wantsPlayback = false
    if (player.isPlaying) player.pause()
    abandonAudioFocus()
  }
  fun clearAudioFocus() {
    resumeOnFocus = false
    wantsPlayback = false
    abandonAudioFocus()
  }
  fun enforceAudioFocusOnPlayback(): Boolean {
    if (focusGranted && wantsPlayback) return true
    if (player.isPlaying) player.pause()
    return false
  }

  fun updateVideoAspectRatio(force: Boolean = false): Boolean {
    if (state() != "playing" && state() != "paused") return false
    val now = SystemClock.elapsedRealtime()
    if (!force && now - lastVideoTrackCheck < 500) return false
    lastVideoTrackCheck = now
    val track = player.currentVideoTrack ?: return false
    if (track.width <= 0 || track.height <= 0) return false
    val sar = if (track.sarNum > 0 && track.sarDen > 0) track.sarNum.toDouble() / track.sarDen else 1.0
    var ratio = track.width.toDouble() * sar / track.height
    if (track.orientation == IMedia.VideoTrack.Orientation.LeftTop ||
      track.orientation == IMedia.VideoTrack.Orientation.LeftBottom ||
      track.orientation == IMedia.VideoTrack.Orientation.RightTop ||
      track.orientation == IMedia.VideoTrack.Orientation.RightBottom) ratio = 1.0 / ratio
    if (!ratio.isFinite() || ratio <= 0) return false
    // Android's PiP window allows only approximately 1:2.39 through 2.39:1.
    ratio = ratio.coerceIn(0.42, 2.38)
    if (videoAspectRatio?.let { kotlin.math.abs(it - ratio) < 0.0001 } == true) return false
    videoAspectRatio = ratio
    output?.onVideoAspectReady(ratio)
    return true
  }

  fun applyPendingSeek() {
    val target = pendingSeek ?: return
    if (!player.isSeekable || player.length <= 0 || (state() != "playing" && state() != "paused")) return
    pendingSeek = null
    player.setTime(target.coerceAtMost(player.length - 1))
  }

  fun state(): String = if (playbackFailed) "error" else when (player.playerState) {
    0 -> "idle"
    1 -> "preparing"
    2 -> "buffering"
    3 -> "playing"
    4 -> "paused"
    5 -> "stopped"
    6 -> "ended"
    7 -> "error"
    else -> "unknown"
  }
  fun currentItemId(): String? = playlistItems.getOrNull(currentIndex)?.id
  fun playbackError(): Map<String, String>? = if (state() == "error")
    mapOf("code" to "PLAYBACK_FAILED", "message" to "The media player reported a playback error.") else null

  fun preparePlaylistReplacement() {
    playbackFailed = false
    transitionPending = false
    resetFailures()
    clearAudioFocus()
    generation++
    autoAdvanceArmed = false
    pendingSeek = null
    lastDuration = 0
    videoAspectRatio = null
    player.stop()
  }

  fun resetOrder() {
    history.clear()
    if (currentIndex in playlist.indices) history.add(currentIndex)
    historyIndex = history.lastIndex
    shuffleRemaining.clear()
    shuffleRemaining.addAll(playlist.indices.filter { it != currentIndex }.shuffled())
  }

  fun editPlaylist(items: List<PlaylistItem>) {
    check(!transitionPending) { "Wait for the current transition to finish" }
    val old = playlistItems
    val currentId = old.getOrNull(currentIndex)?.id
    val newIndices = items.mapIndexed { index, item -> item.id to index }.toMap()
    val mappedHistory = history.mapIndexedNotNull { offset, index ->
      old.getOrNull(index)?.id?.let { newIndices[it] }?.let { offset to it }
    }
    val mappedRemaining = shuffleRemaining.mapNotNull { old.getOrNull(it)?.id?.let(newIndices::get) }
    if (currentId != null && currentId !in newIndices) {
      clearAudioFocus()
      generation++
      playbackFailed = false
      autoAdvanceArmed = false
      pendingSeek = null
      player.stop()
      lastDuration = 0
      videoAspectRatio = null
      audioDelayApplied = false
    }
    playlistItems = items
    failedItems.retainAll(items.map { it.id }.toSet())
    playlist = items.map { it.uri }
    currentIndex = currentId?.let { newIndices[it] } ?: -1
    val oldHistoryIndex = historyIndex
    history.clear()
    history.addAll(mappedHistory.map { it.second })
    historyIndex = mappedHistory.count { it.first <= oldHistoryIndex } - 1
    shuffleRemaining.clear()
    shuffleRemaining.addAll(mappedRemaining)
    shuffleRemaining.addAll(items.indices.filter { index -> old.none { it.id == items[index].id } }.shuffled())
    pipControls?.refresh()
    onPlaylistEdited?.invoke()
  }

  fun setShuffle(enabled: Boolean) {
    if (shuffleEnabled == enabled) return
    shuffleEnabled = enabled
    resetOrder()
  }

  private fun recordSelection(index: Int) {
    while (history.lastIndex > historyIndex) history.removeAt(history.lastIndex)
    if (history.lastOrNull() != index) history.add(index)
    while (history.size > 1000) history.removeAt(0)
    historyIndex = history.lastIndex
    shuffleRemaining.remove(index)
  }

  fun canNext(): Boolean {
    if (playlist.isEmpty()) return false
    if (currentIndex < 0) return true
    if (shuffleEnabled) return historyIndex + 1 < history.size || shuffleRemaining.isNotEmpty() || repeatMode == "all"
    return currentIndex + 1 < playlist.size || repeatMode == "all"
  }

  fun canPrevious(): Boolean {
    if (currentIndex !in playlist.indices) return false
    if (shuffleEnabled) return historyIndex > 0
    return currentIndex > 0 || repeatMode == "all"
  }

  fun select(index: Int, record: Boolean = true, preservingFailures: Boolean = false) {
    require(index in playlist.indices) { "No playlist item in that direction" }
    requestAudioFocus()
    playbackFailed = false
    if (!preservingFailures) failedItems.clear()
    lastReportedState = ""
    resumeOnFocus = false
    wantsPlayback = true
    if (record && shuffleEnabled) recordSelection(index)
    generation++
    autoAdvanceArmed = false
    if (index == currentIndex && state() == "ended") {
      pendingSeek = 0
      player.play()
      applyPendingSeek()
      return
    }
    if (pipControls?.isActive() == true) output?.beginPictureInPictureTransition()
    player.stop()
    pendingSeek = null
    lastDuration = 0
    videoAspectRatio = null
    lastVideoTrackCheck = 0
    currentIndex = index
    transitionPending = true
    audioDelayApplied = false
    val media = Media(libVlc, playlist[index])
    try { player.media = media } finally { media.release() }
    player.play()
  }

  fun resetFailures() { failedItems.clear() }

  fun handlePlaybackFailure() {
    val itemId = currentItemId() ?: return
    if (failurePolicy != "skip" || !failedItems.add(itemId) || playlistItems.isEmpty()) return
    val candidates = if (shuffleEnabled) {
      shuffleRemaining.asReversed().filter { it in playlistItems.indices && playlistItems[it].id !in failedItems } +
        (if (repeatMode == "all") playlistItems.indices.filter { playlistItems[it].id !in failedItems } else emptyList())
    } else if (repeatMode == "all") {
      (1..playlistItems.size).map { (currentIndex + it) % playlistItems.size }.filter { playlistItems[it].id !in failedItems }
    } else {
      playlistItems.indices.filter { it > currentIndex && playlistItems[it].id !in failedItems }
    }
    val index = candidates.firstOrNull() ?: return
    select(index, preservingFailures = true)
  }

  fun next(automatic: Boolean = false): Boolean {
    if (automatic && repeatMode == "one" && currentIndex in playlist.indices) {
      select(currentIndex, false, preservingFailures = true)
      return true
    }
    if (!canNext()) return false
    if (currentIndex < 0) { select(0, preservingFailures = automatic); return true }
    if (shuffleEnabled) {
      if (historyIndex + 1 < history.size) {
        historyIndex++
        select(history[historyIndex], false, preservingFailures = automatic)
      } else {
        if (shuffleRemaining.isEmpty()) {
          shuffleRemaining.addAll(playlist.indices.filter { it != currentIndex }.shuffled())
          if (shuffleRemaining.isEmpty()) shuffleRemaining.add(currentIndex)
        }
        select(shuffleRemaining.removeAt(shuffleRemaining.lastIndex), preservingFailures = automatic)
      }
    } else select((currentIndex + 1) % playlist.size, preservingFailures = automatic)
    return true
  }

  fun previous(): Boolean {
    if (!canPrevious()) return false
    if (shuffleEnabled) {
      historyIndex--
      select(history[historyIndex], false)
    } else select((currentIndex - 1 + playlist.size) % playlist.size)
    return true
  }

  fun release() {
    released = true
    progressHandler.removeCallbacks(progressRunnable)
    onProgress = null
    onPlaylistEdited = null
    clearAudioFocus()
    appContext.unregisterReceiver(noisyReceiver)
    pipControls?.close()
    pipControls = null
    player.setEventListener(null)
    output?.detach()
    player.stop()
    player.release()
    libVlc.release()
  }
}

private object Sessions {
  val items = mutableMapOf<String, PlayerSession>()
  var pictureInPictureSessionId: String? = null
  fun get(id: String): PlayerSession = items[id]
    ?: throw IllegalStateException("Session does not exist or has been released")
}

private fun pictureInPictureProvider(activity: Activity): Class<*>? = runCatching {
  val provider = Class.forName("androidx.core.app.OnPictureInPictureModeChangedProvider")
  val info = Class.forName("androidx.core.app.PictureInPictureModeChangedInfo")
  provider.getMethod("addOnPictureInPictureModeChangedListener", Consumer::class.java)
  provider.getMethod("removeOnPictureInPictureModeChangedListener", Consumer::class.java)
  info.getMethod("isInPictureInPictureMode")
  provider.takeIf { it.isInstance(activity) }
}.getOrNull()

private class PictureInPictureControls(
  private val context: Context,
  activity: Activity,
  private val sessionId: String,
  private val session: PlayerSession,
  private var lastAspectRatio: Double,
  private val onModeChanged: (Boolean) -> Unit
) {
  private val activityRef = WeakReference(activity)
  private val modeProvider = pictureInPictureProvider(activity)
  private var modeListenerRegistered = false
  private val modeListener = Consumer<Any> { info ->
    val active = runCatching { info.javaClass.getMethod("isInPictureInPictureMode").invoke(info) as Boolean }.getOrNull() ?: return@Consumer
    if (Sessions.pictureInPictureSessionId == sessionId && Sessions.items[sessionId] === session) {
      onModeChanged(active)
      if (!active) {
        session.pipGeneration++
        session.output?.updateVideoScale(false)
        session.output?.cancelPictureInPictureTransition()
        if (session.pipControls === this) session.pipControls = null
        Sessions.pictureInPictureSessionId = null
        close()
      }
    }
  }
  private val action = "${context.packageName}.expo.summonvlc.PIP_CONTROL"
  private var registered = false
  private val receiver = object : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
      if (intent.action != action || Sessions.pictureInPictureSessionId != sessionId ||
        Sessions.items[sessionId] !== session) return
      val activity = activityRef.get() ?: return
      if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || !activity.isInPictureInPictureMode) return
      when (intent.getStringExtra("command")) {
        "rewind" -> seekBy(-10_000)
        "forward" -> seekBy(10_000)
        "play" -> runCatching { session.playPlayback() }
        "pause" -> session.pausePlayback()
      }
      refresh()
    }
  }

  private fun seekBy(offset: Long) {
    val player = session.player
    val duration = maxOf(player.length, session.lastDuration)
    if (!player.isSeekable || duration <= 0) return
    val target = (player.time.coerceAtLeast(0) + offset).coerceIn(0, duration - 1)
    player.setTime(target)
  }

  fun register() {
    val filter = IntentFilter(action)
    filter.addDataScheme("summonvlc")
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
    } else {
      @Suppress("UnspecifiedRegisterReceiverFlag")
      context.registerReceiver(receiver, filter)
    }
    registered = true
    modeListenerRegistered = modeProvider?.let { provider ->
      runCatching {
        provider.getMethod("addOnPictureInPictureModeChangedListener", Consumer::class.java).invoke(activityRef.get(), modeListener)
        true
      }.getOrDefault(false)
    } ?: false
  }

  fun actions(): List<RemoteAction> {
    val playing = session.player.isPlaying
    val seekable = session.player.isSeekable && maxOf(session.player.length, session.lastDuration) > 0
    val previous = makeAction("rewind", "Back 10 seconds", R.drawable.expo_summon_vlc_replay_10, seekable)
    val playback = makeAction(if (playing) "pause" else "play", if (playing) "Pause" else "Play",
      if (playing) R.drawable.expo_summon_vlc_pause else R.drawable.expo_summon_vlc_play_arrow, true)
    val next = makeAction("forward", "Forward 10 seconds", R.drawable.expo_summon_vlc_forward_10, seekable)
    val limit = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) activityRef.get()?.maxNumPictureInPictureActions ?: 0 else 0
    return when {
      limit >= 3 -> listOf(previous, playback, next)
      limit == 2 -> listOf(playback, next)
      limit == 1 -> listOf(playback)
      else -> emptyList()
    }
  }

  private fun makeAction(command: String, label: String, icon: Int, enabled: Boolean): RemoteAction {
    val intent = Intent(action).setPackage(context.packageName)
      .setData(Uri.parse("summonvlc://pip/$sessionId/$command"))
      .putExtra("command", command)
    val pendingIntent = PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    return RemoteAction(Icon.createWithResource(context, icon), label, label, pendingIntent).apply { isEnabled = enabled }
  }

  fun refresh() {
    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || Sessions.pictureInPictureSessionId != sessionId) return
    val activity = activityRef.get() ?: return
    if (!activity.isInPictureInPictureMode) return
    try {
      session.videoAspectRatio?.let { lastAspectRatio = it }
      val builder = PictureInPictureParams.Builder()
        .setAspectRatio(Rational((lastAspectRatio * 10000).toInt(), 10000))
        .setActions(actions())
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setSeamlessResizeEnabled(false)
      val params = builder.build()
      activity.setPictureInPictureParams(params)
    } catch (_: IllegalStateException) {
      // The activity may leave PiP between the state check and the update.
      session.output?.cancelPictureInPictureTransition()
    } catch (error: IllegalArgumentException) {
      Log.w("ExpoSummonVlc", "PiP aspect ratio update was rejected", error)
      session.output?.cancelPictureInPictureTransition()
    }
  }

  fun isActive(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
    Sessions.pictureInPictureSessionId == sessionId && activityRef.get()?.isInPictureInPictureMode == true

  fun eventsSupported(): Boolean = modeListenerRegistered

  fun close() {
    if (registered) {
      if (modeListenerRegistered) {
        runCatching { modeProvider?.getMethod("removeOnPictureInPictureModeChangedListener", Consumer::class.java)?.invoke(activityRef.get(), modeListener) }
        modeListenerRegistered = false
      }
      context.unregisterReceiver(receiver)
      registered = false
    }
  }
}

class PlayerView(context: Context, appContext: AppContext) : ExpoView(context, appContext) {
  override val shouldUseAndroidLayout = true
  private val output = VLCVideoLayout(context)
  private val videoContainer = FrameLayout(context)
  private val transitionPlaceholder = View(context)
  private var sessionId: String? = null
  private var transitionPending = false
  private var transitionAspectRatio: Double? = null
  private val transitionFallback = Runnable {
    if (transitionPending) {
      sessionId?.let { Sessions.items[it] }?.player?.updateVideoSurfaces()
      cancelPictureInPictureTransition()
    }
  }
  private var resizeMode = MediaPlayer.ScaleType.SURFACE_BEST_FIT
  private var appliedScale: MediaPlayer.ScaleType? = null

  init {
    val match = FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT)
    videoContainer.addView(output, match)
    transitionPlaceholder.setBackgroundColor(Color.BLACK)
    transitionPlaceholder.visibility = View.GONE
    videoContainer.addView(transitionPlaceholder, FrameLayout.LayoutParams(FrameLayout.LayoutParams.MATCH_PARENT, FrameLayout.LayoutParams.MATCH_PARENT))
    addView(videoContainer, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT))
    output.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ -> tryFinishPictureInPictureTransition() }
  }

  fun attach(id: String?) {
    if (sessionId == id) return
    detach()
    val session = id?.let { Sessions.items[it] } ?: return
    if (session.output != null) return
    sessionId = id
    session.output = this
    session.player.attachViews(output, null, false, false)
    updateVideoScale()
  }

  fun setResizeMode(mode: String?) {
    resizeMode = when (mode) {
      "cover" -> MediaPlayer.ScaleType.SURFACE_FIT_SCREEN
      "fill" -> MediaPlayer.ScaleType.SURFACE_FILL
      else -> MediaPlayer.ScaleType.SURFACE_BEST_FIT
    }
    updateVideoScale()
  }

  fun updateVideoScale(pictureInPicture: Boolean? = null) {
    val session = sessionId?.let { Sessions.items[it] } ?: return
    val pip = pictureInPicture ?: (session.pipControls?.isActive() == true)
    val scale = if (pip) MediaPlayer.ScaleType.SURFACE_BEST_FIT else resizeMode
    if (appliedScale != scale) {
      session.player.setVideoScale(scale)
      appliedScale = scale
    }
  }

  fun beginPictureInPictureTransition() {
    output.removeCallbacks(transitionFallback)
    transitionPending = true
    transitionAspectRatio = null
    transitionPlaceholder.visibility = View.VISIBLE
    // Insets or an app-managed layout can prevent the output ratio matching the video ratio.
    output.postDelayed(transitionFallback, 1000)
  }

  fun onVideoAspectReady(ratio: Double) {
    if (!transitionPending) return
    transitionAspectRatio = ratio
    tryFinishPictureInPictureTransition()
  }

  fun cancelPictureInPictureTransition() {
    output.removeCallbacks(transitionFallback)
    transitionPending = false
    transitionAspectRatio = null
    transitionPlaceholder.visibility = View.GONE
  }

  override fun onConfigurationChanged(newConfig: Configuration) {
    super.onConfigurationChanged(newConfig)
    post {
      updateVideoScale()
      tryFinishPictureInPictureTransition()
    }
  }

  private fun tryFinishPictureInPictureTransition() {
    if (!transitionPending) return
    val session = sessionId?.let { Sessions.items[it] }
    if (session?.pipControls?.isActive() != true) {
      cancelPictureInPictureTransition()
      return
    }
    val target = transitionAspectRatio ?: return
    if (output.width <= 0 || output.height <= 0) return
    val actual = output.width.toDouble() / output.height
    if (kotlin.math.abs(actual / target - 1.0) > 0.03) return
    output.post {
      if (!transitionPending || transitionAspectRatio != target) return@post
      val currentSession = sessionId?.let { Sessions.items[it] }
      if (currentSession?.pipControls?.isActive() != true ||
        (output.width > 0 && output.height > 0 &&
          kotlin.math.abs((output.width.toDouble() / output.height) / target - 1.0) <= 0.03)) {
        currentSession?.player?.updateVideoSurfaces()
        cancelPictureInPictureTransition()
      }
    }
  }

  fun detach() {
    cancelPictureInPictureTransition()
    val session = sessionId?.let { Sessions.items[it] }
    if (session?.output === this) {
      session.player.detachViews()
      session.output = null
    }
    sessionId = null
    appliedScale = null
  }
}

class ExpoSummonVlcModule : Module() {
  private fun requestPictureInPictureStop(id: String, activity: Activity) {
    Sessions.get(id)
    check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) { "Picture-in-picture requires Android 8.0 or later" }
    if (activity.isInPictureInPictureMode || Sessions.pictureInPictureSessionId == id) {
      check(Sessions.pictureInPictureSessionId == id) { "Another session is using Picture-in-picture" }
      activity.startActivity(Intent(activity, activity.javaClass).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
  }
  private fun publishPlaybackState(id: String, session: PlayerSession) {
    if (Sessions.items[id] !== session) return
    val state = session.state()
    val key = "${session.currentIndex}:${session.currentItemId() ?: ""}:$state"
    if (key == session.lastReportedState) return
    session.lastReportedState = key
    session.eventSequence++
    val identity = mapOf("sessionId" to id, "currentIndex" to session.currentIndex,
      "currentItemId" to session.currentItemId(), "sequence" to session.eventSequence)
    sendEvent("onPlaybackStateChange", identity + ("state" to state))
    session.playbackError()?.let { failure -> sendEvent("onPlaybackError", identity + failure) }
  }
  private fun playlistItems(values: List<Map<String, String>>): List<PlaylistItem> {
    val items = values.map { PlaylistItem.parse(it) }
    require(items.map { it.id }.toSet().size == items.size) { "Playlist item IDs must be unique" }
    return items
  }
  private fun subtitleStyleOptions(style: Map<String, Double>): List<String> {
    val limits = mapOf("fontScale" to (0.5..3.0), "backgroundColor" to (0.0..16777215.0),
      "backgroundOpacity" to (0.0..255.0), "outlineColor" to (0.0..16777215.0), "outlineWidth" to (0.0..5.0), "bottomMargin" to (0.0..500.0))
    require(style.keys - setOf("alignment", "textColor") == limits.keys &&
      style["textColor"].let { it == null || (it.isFinite() && it in 0.0..16777215.0 && it % 1.0 == 0.0) } &&
      style["alignment"].let { it == null || it in listOf(-1.0, 0.0, 1.0, 2.0) } && limits.all { (key, range) ->
      val value = style[key]
      value != null && value.isFinite() && value in range && (key == "fontScale" || value % 1.0 == 0.0)
    }) { "Invalid subtitle style" }
    val options = mutableListOf("--freetype-rel-fontsize=${(16.0 / style.getValue("fontScale")).toInt().coerceAtLeast(1)}",
      "--freetype-background-color=${style.getValue("backgroundColor").toInt()}",
      "--freetype-background-opacity=${style.getValue("backgroundOpacity").toInt()}",
      "--freetype-outline-color=${style.getValue("outlineColor").toInt()}",
      "--freetype-outline-opacity=255",
      "--freetype-outline-thickness=${style.getValue("outlineWidth").toInt()}",
      "--sub-margin=${style.getValue("bottomMargin").toInt()}")
    style["textColor"]?.let { options.add("--freetype-color=${it.toInt()}") }
    style["alignment"]?.let { options.add("--subsdec-align=${it.toInt()}") }
    return options
  }
  private fun createPlayerSession(options: List<String>?): String {
    val context = appContext.reactContext ?: throw IllegalStateException("React context is unavailable")
    val id = UUID.randomUUID().toString()
    val session = PlayerSession(context, options)
    Sessions.items[id] = session
    session.onProgress = {
      if (Sessions.items[id] === session) {
        sendEvent("onPlaybackProgress", mapOf("sessionId" to id, "currentIndex" to session.currentIndex,
          "currentItemId" to session.currentItemId(), "mediaRevision" to session.generation.toString(),
          "sequence" to session.progressSequence, "positionMillis" to session.player.time.coerceAtLeast(0),
          "durationMillis" to maxOf(session.lastDuration, session.player.length).coerceAtLeast(0)))
      }
    }
    session.startProgressUpdates()
    session.onPlaylistEdited = { publishPlaybackState(id, session) }
    session.player.setEventListener { event ->
      val eventType = event.type
      val generation = session.generation
      if (eventType == MediaPlayer.Event.SeekableChanged || eventType == MediaPlayer.Event.Playing ||
          eventType == MediaPlayer.Event.TimeChanged || eventType == MediaPlayer.Event.LengthChanged ||
          eventType == MediaPlayer.Event.ESAdded || eventType == MediaPlayer.Event.ESDeleted || eventType == MediaPlayer.Event.ESSelected ||
          eventType == MediaPlayer.Event.Vout) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
          if (Sessions.items[id] === session && session.generation == generation) {
            session.applyPendingSeek()
            if (eventType == MediaPlayer.Event.TimeChanged && !session.transitionPending && session.player.isPlaying && session.player.time >= 1000) session.resetFailures()
            if (session.updateVideoAspectRatio()) session.pipControls?.refresh()
            if (eventType == MediaPlayer.Event.ESAdded || eventType == MediaPlayer.Event.ESDeleted || eventType == MediaPlayer.Event.ESSelected) {
              sendEvent("onTracksChanged", mapOf("sessionId" to id, "revision" to generation.toString()))
            }
          }
        }
      }
      if (eventType in setOf(MediaPlayer.Event.Opening, MediaPlayer.Event.Buffering,
          MediaPlayer.Event.Playing, MediaPlayer.Event.Paused, MediaPlayer.Event.Stopped,
          MediaPlayer.Event.EndReached, MediaPlayer.Event.EncounteredError)) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
          if (Sessions.items[id] === session && session.generation == generation) {
            if (eventType == MediaPlayer.Event.EncounteredError) {
              session.playbackFailed = true
              session.autoAdvanceArmed = false
            }
            if (eventType == MediaPlayer.Event.EncounteredError || eventType == MediaPlayer.Event.Playing || eventType == MediaPlayer.Event.Paused) session.transitionPending = false
            if (eventType == MediaPlayer.Event.Playing && !session.enforceAudioFocusOnPlayback()) return@post
            if (eventType == MediaPlayer.Event.Playing && !session.audioDelayApplied) {
              session.audioDelayApplied = session.player.setAudioDelay(session.audioDelayMillis * 1000)
            }
            val state = session.state()
            if (state == "error") { session.output?.cancelPictureInPictureTransition(); session.clearAudioFocus() }
            publishPlaybackState(id, session)
            if (eventType == MediaPlayer.Event.Playing && state == "playing") {
              session.autoAdvanceArmed = session.currentIndex in session.playlist.indices
            } else if (eventType == MediaPlayer.Event.EncounteredError && state == "error") {
              runCatching { session.handlePlaybackFailure() }
            } else if (eventType == MediaPlayer.Event.EndReached && state == "ended" && session.autoAdvanceArmed) {
              session.autoAdvanceArmed = false
              if (session.pendingSeek == null && !session.next(automatic = true)) session.clearAudioFocus()
            }
            session.pipControls?.refresh()
          }
        }
      }
    }
    return id
  }
  private fun startPictureInPictureSession(id: String) {
      val session = Sessions.get(id)
      check(Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) { "Picture-in-picture requires Android 8.0 or later" }
      val activity = appContext.currentActivity ?: throw IllegalStateException("Activity is unavailable")
      check(activity.packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) { "Picture-in-picture is unsupported on this device" }
      val output = session.output ?: throw IllegalStateException("The session has no video output")
      check(output.isAttachedToWindow && output.width > 0 && output.height > 0) { "Video output is not ready" }
      check(session.player.hasMedia()) { "The session has no media" }
      check(!activity.isInPictureInPictureMode) { "Picture-in-picture is already active" }
      val bounds = Rect()
      val hasVisibleBounds = output.getGlobalVisibleRect(bounds) && !bounds.isEmpty
      session.updateVideoAspectRatio(force = true)
      val ratio = session.videoAspectRatio ?: (output.width.toDouble() / output.height).coerceIn(0.42, 2.38)
      session.pipControls?.close()
      val controls = PictureInPictureControls(activity.applicationContext, activity, id, session, ratio) { active ->
        sendEvent("onPictureInPictureStateChange", mapOf("sessionId" to id, "supported" to true,
          "active" to active, "reason" to null, "eventsSupported" to true, "stopSupported" to true))
      }
      controls.register()
      try {
        Sessions.pictureInPictureSessionId = id
        session.pipControls = controls
        session.pipGeneration++
        output.updateVideoScale(true)
        val builder = PictureInPictureParams.Builder()
          .setAspectRatio(Rational((ratio * 10000).toInt(), 10000))
          .setActions(controls.actions())
        if (hasVisibleBounds) builder.setSourceRectHint(bounds)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) builder.setSeamlessResizeEnabled(false)
        val params = builder.build()
        check(activity.enterPictureInPictureMode(params)) { "Picture-in-picture entry was rejected; check activity configuration" }
      } catch (error: Exception) {
        output.updateVideoScale(false)
        controls.close()
        session.pipControls = null
        if (Sessions.pictureInPictureSessionId == id) Sessions.pictureInPictureSessionId = null
        throw error
      }
      Unit
  }

  override fun definition() = ModuleDefinition {
    Name("ExpoSummonVlc")
    Events("onPlaybackStateChange", "onPlaybackProgress", "onPlaybackError", "onTracksChanged", "onPictureInPictureStateChange", "onPictureInPictureExitTest")

    AsyncFunction("startFrameProbe") { _: String ->
      unsupportedFrameProbe()
    }
    AsyncFunction("getFrameProbeStatus") { mapOf("running" to false, "frames" to 0) }
    AsyncFunction("stopFrameProbe") { Unit }

    AsyncFunction("inspectMedia") { id: String, uri: String, timeout: Int, promise: Promise ->
      val context = appContext.reactContext
      if (context == null) promise.reject("ERR_MEDIA_CONTEXT", "React context is unavailable", null)
      else MediaAnalysis.inspect(context, id, uri, timeout, promise)
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("generateThumbnail") { id: String, uri: String, position: Double, timeout: Int, promise: Promise ->
      val context = appContext.reactContext
      if (context == null) promise.reject("ERR_MEDIA_CONTEXT", "React context is unavailable", null)
      else MediaAnalysis.thumbnail(context, id, uri, position, timeout, promise)
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("cancelMediaJob") { id: String -> MediaAnalysis.cancel(id) }.runOnQueue(Queues.MAIN)

    AsyncFunction("setControlCenterEnabled") { id: String, enabled: Boolean ->
      Sessions.get(id)
      if (enabled) throw UnsupportedOperationException("Control Center integration is available on iOS only")
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("getTracks") { id: String ->
      val session = Sessions.get(id)
      check(session.state() == "playing" || session.state() == "paused") { "Tracks are unavailable until media is playing or paused" }
      val player = session.player
      val media = player.media
      val languages = mutableMapOf<Pair<Int, Int>, String>()
      try {
        if (media != null) for (index in 0 until media.trackCount) {
          val track = media.getTrack(index) ?: continue
          val language = track.language ?: continue
          languages[track.type to track.id] = language
        }
      } finally { media?.release() }
      fun describe(tracks: Array<MediaPlayer.TrackDescription>?, selected: Int, mediaType: Int): List<Map<String, Any?>> =
        (tracks ?: emptyArray()).filter { it.id != -1 }.map { track ->
          mapOf("id" to track.id.toString(), "name" to track.name, "language" to languages[mediaType to track.id], "selected" to (track.id == selected))
        }
      mapOf("revision" to session.generation.toString(), "currentIndex" to session.currentIndex,
        "audio" to describe(player.audioTracks, player.audioTrack, IMedia.Track.Type.Audio),
        "subtitles" to describe(player.spuTracks, player.spuTrack, IMedia.Track.Type.Text))
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("selectTrack") { id: String, type: String, identifier: String?, revision: String ->
      val session = Sessions.get(id)
      require(type == "audio" || type == "subtitle") { "Invalid track type" }
      require(identifier != null || type == "subtitle") { "Audio cannot be disabled" }
      check(revision == session.generation.toString() && (session.state() == "playing" || session.state() == "paused")) { "Track list is stale; refresh it first" }
      val player = session.player
      val nativeId = identifier?.toIntOrNull() ?: if (identifier == null) -1 else throw IllegalArgumentException("Invalid track identifier")
      if (identifier != null) {
        val tracks = if (type == "audio") player.audioTracks else player.spuTracks
        check(nativeId != -1 && tracks?.any { it.id == nativeId } == true) { "Track is unavailable" }
      }
      val selected = if (type == "audio") player.setAudioTrack(nativeId)
        else if (nativeId == -1 && player.spuTrack == -1) true else player.setSpuTrack(nativeId)
      check(selected) { "Track selection failed" }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("createSession") { createPlayerSession(null) }.runOnQueue(Queues.MAIN)
    AsyncFunction("createSessionWithSubtitleStyle") { style: Map<String, Double> ->
      createPlayerSession(subtitleStyleOptions(style))
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setSubtitleFontScale") { id: String, scale: Double ->
      Sessions.get(id)
      require(scale.isFinite() && scale in 0.5..3.0) { "Font scale must be between 0.5 and 3.0" }
      unsupportedLiveSubtitleScale()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("getSubtitleStyleCapabilities") { mapOf("creationStyle" to true, "liveFontScale" to false) }.runOnQueue(Queues.MAIN)

    AsyncFunction("load") { id: String, uri: String ->
      val parsed = Uri.parse(uri)
      require(!parsed.scheme.isNullOrBlank()) { "Invalid media URI" }
      val session = Sessions.get(id)
      session.playbackFailed = false
      session.transitionPending = false
      session.resetFailures()
      session.clearAudioFocus()
      session.generation++
      session.autoAdvanceArmed = false
      session.player.stop()
      session.pendingSeek = null
      session.lastDuration = 0
      session.videoAspectRatio = null
      session.playlist = emptyList()
      session.playlistItems = emptyList()
      session.currentIndex = -1
      session.resetOrder()
      val media = Media(session.libVlc, parsed)
      try { session.player.media = media } finally { media.release() }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setPlaylist") { id: String, uris: List<String> ->
      require(uris.isNotEmpty()) { "Playlist cannot be empty" }
      val parsed = uris.map { Uri.parse(it) }
      require(parsed.all { !it.scheme.isNullOrBlank() }) { "Invalid media URI" }
      val session = Sessions.get(id)
      session.preparePlaylistReplacement()
      session.playlist = parsed
      session.playlistItems = parsed.map { PlaylistItem(UUID.randomUUID().toString(), it, null) }
      session.currentIndex = -1
      session.resetOrder()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("selectPlaylistItem") { id: String, index: Int ->
      Sessions.get(id).select(index)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setPlaylistItems") { id: String, values: List<Map<String, String>> ->
      val items = playlistItems(values)
      require(items.isNotEmpty()) { "Playlist cannot be empty" }
      val session = Sessions.get(id)
      session.preparePlaylistReplacement()
      session.playlistItems = items
      session.playlist = items.map { it.uri }
      session.currentIndex = -1
      session.resetOrder()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("getPlaylist") { id: String -> Sessions.get(id).playlistItems.map { it.toMap() } }.runOnQueue(Queues.MAIN)
    AsyncFunction("getCurrentItem") { id: String ->
      val session = Sessions.get(id)
      session.playlistItems.getOrNull(session.currentIndex)?.toMap()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("insertItem") { id: String, index: Int, value: Map<String, String> ->
      val session = Sessions.get(id)
      require(index in 0..session.playlistItems.size) { "Invalid playlist index" }
      val values = session.playlistItems.map { it.toMap() }.toMutableList()
      values.add(index, value)
      session.editPlaylist(playlistItems(values))
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("addItem") { id: String, value: Map<String, String> ->
      val session = Sessions.get(id)
      session.editPlaylist(playlistItems(session.playlistItems.map { it.toMap() } + value))
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("removeItem") { id: String, itemId: String ->
      val session = Sessions.get(id)
      require(session.playlistItems.any { it.id == itemId }) { "Playlist item does not exist" }
      session.editPlaylist(session.playlistItems.filter { it.id != itemId })
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("moveItem") { id: String, from: Int, to: Int ->
      val session = Sessions.get(id)
      val items = session.playlistItems.toMutableList()
      require(from in items.indices && to in items.indices) { "Invalid playlist index" }
      items.add(to, items.removeAt(from))
      session.editPlaylist(items)
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("clearPlaylist") { id: String -> Sessions.get(id).editPlaylist(emptyList()) }.runOnQueue(Queues.MAIN)
    AsyncFunction("selectItem") { id: String, itemId: String ->
      val session = Sessions.get(id)
      val index = session.playlistItems.indexOfFirst { it.id == itemId }
      require(index >= 0) { "Playlist item does not exist" }
      session.select(index)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("next") { id: String ->
      val session = Sessions.get(id)
      check(session.next()) { "No playlist item in that direction" }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("previous") { id: String ->
      val session = Sessions.get(id)
      check(session.previous()) { "No playlist item in that direction" }
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setRepeatMode") { id: String, mode: String ->
      require(mode in listOf("off", "one", "all")) { "Invalid repeat mode" }
      val session = Sessions.get(id)
      session.repeatMode = mode
      session.pipControls?.refresh()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setShuffleEnabled") { id: String, enabled: Boolean ->
      val session = Sessions.get(id)
      session.setShuffle(enabled)
      session.pipControls?.refresh()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setTransitionTimeout") { id: String, _: Double ->
      Sessions.get(id)
      unsupportedTransitionTimeout()
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setFailurePolicy") { id: String, policy: String ->
      require(policy == "stop" || policy == "skip") { "Invalid playback failure policy" }
      Sessions.get(id).failurePolicy = policy
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("setPlaybackRate") { id: String, rate: Double ->
      require(rate.isFinite() && rate in 0.25..4.0) { "Playback rate must be between 0.25 and 4" }
      val session = Sessions.get(id)
      session.player.setRate(rate.toFloat())
      session.playbackRate = rate
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setVolume") { id: String, volume: Double ->
      require(volume.isFinite() && volume in 0.0..1.0) { "Volume must be between 0 and 1" }
      val session = Sessions.get(id)
      val value = kotlin.math.round(volume * 100).toInt()
      check(session.muted || session.player.setVolume(value) == 0) { "Volume could not be set" }
      session.volume = value
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setMuted") { id: String, muted: Boolean ->
      val session = Sessions.get(id)
      check(session.player.setVolume(if (muted) 0 else session.volume) == 0) { "Volume could not be set" }
      session.muted = muted
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("setAudioDelay") { id: String, delay: Double ->
      require(delay.isFinite() && delay in -10000.0..10000.0 && delay % 1.0 == 0.0) { "Audio delay must be an integer between -10000 and 10000 milliseconds" }
      val session = Sessions.get(id)
      check(session.state() == "playing" || session.state() == "paused") { "Audio delay requires playing or paused media" }
      val value = delay.toLong()
      check(session.player.setAudioDelay(value * 1000)) { "Audio delay could not be set" }
      session.audioDelayMillis = value
      session.audioDelayApplied = true
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("getPlaybackStatus") { id: String ->
      val session = Sessions.get(id)
      session.applyPendingSeek()
      if (session.player.length > 0) session.lastDuration = session.player.length
      mapOf("state" to session.state(), "currentIndex" to session.currentIndex,
        "currentItemId" to session.currentItemId(), "eventSequence" to session.eventSequence, "error" to session.playbackError(),
        "mediaRevision" to session.generation.toString(), "progressSequence" to session.progressSequence,
        "positionMillis" to session.player.time.coerceAtLeast(0),
        "playbackRate" to session.playbackRate, "volume" to (session.volume / 100.0), "muted" to session.muted,
        "audioDelayMillis" to session.audioDelayMillis, "audioDelayApplied" to session.audioDelayApplied,
        "durationMillis" to session.lastDuration,
        "isSeekable" to (session.player.isSeekable || (session.state() == "ended" && session.lastDuration > 0)),
        "repeatMode" to session.repeatMode, "shuffleEnabled" to session.shuffleEnabled,
        "failurePolicy" to session.failurePolicy,
        "canNext" to session.canNext(), "canPrevious" to session.canPrevious())
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("getPictureInPictureState") { id: String ->
      val session = Sessions.get(id)
      val activity = appContext.currentActivity
      val supported = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
        activity?.packageManager?.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE) == true
      session.output?.updateVideoScale(supported && activity?.isInPictureInPictureMode == true && Sessions.pictureInPictureSessionId == id)
      mapOf<String, Any?>(
        "supported" to supported,
        "active" to (supported && activity?.isInPictureInPictureMode == true && Sessions.pictureInPictureSessionId == id),
        "reason" to if (activity == null) "activity_unavailable" else if (!supported) "device_unsupported" else null,
        "eventsSupported" to (session.pipControls?.eventsSupported() ?: (activity != null && pictureInPictureProvider(activity) != null)),
        "stopSupported" to supported
      )
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("startPictureInPicture") { id: String ->
      startPictureInPictureSession(id)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("startPictureInPictureExitTest") { id: String, delay: Double ->
      require(delay.isFinite() && delay in 1000.0..30000.0) { "Invalid test delay" }
      val session = Sessions.get(id)
      val activity = appContext.currentActivity ?: throw IllegalStateException("Activity is unavailable")
      startPictureInPictureSession(id)
      val generation = session.pipGeneration
      val activityRef = WeakReference(activity)
      val handler = android.os.Handler(android.os.Looper.getMainLooper())
      handler.postDelayed({
        if (Sessions.items[id] !== session || session.pipGeneration != generation) return@postDelayed
        try {
          val currentActivity = activityRef.get() ?: throw IllegalStateException("Activity is unavailable")
          requestPictureInPictureStop(id, currentActivity)
          sendEvent("onPictureInPictureExitTest", mapOf("sessionId" to id, "stage" to "requested", "message" to null))
          handler.postDelayed({
            if (Sessions.items[id] === session && session.pipGeneration == generation && session.pipControls?.isActive() == true) {
              sendEvent("onPictureInPictureExitTest", mapOf("sessionId" to id, "stage" to "still_active", "message" to "PiP remains active after the exit request."))
            }
          }, 3000)
        } catch (error: Exception) {
          sendEvent("onPictureInPictureExitTest", mapOf("sessionId" to id, "stage" to "failed", "message" to (error.message ?: "PiP exit request failed.")))
        }
      }, delay.toLong())
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("stopPictureInPicture") { id: String ->
      val activity = appContext.currentActivity ?: throw IllegalStateException("Activity is unavailable")
      requestPictureInPictureStop(id, activity)
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("seekTo") { id: String, millis: Double, options: Map<String, String>? ->
      val precision = options?.get("precision") ?: "fast"
      require(precision == "fast" || precision == "precise") { "Invalid seek precision" }
      require(precision != "precise") { "Precise seek is not supported on Android" }
      require(millis.isFinite() && millis >= 0) { "Invalid seek position" }
      val session = Sessions.get(id)
      val player = session.player
      val duration = maxOf(player.length, session.lastDuration)
      check(duration > 0 && (player.isSeekable || session.state() == "ended")) { "Media is not seekable" }
      val target = millis.coerceAtMost((duration - 1).toDouble()).toLong()
      if (session.state() == "ended") {
        session.pendingSeek = target
        session.playPlayback()
        session.applyPendingSeek()
      } else {
        player.setTime(target)
      }
      Unit
    }.runOnQueue(Queues.MAIN)

    AsyncFunction("play") { id: String -> Sessions.get(id).playPlayback() }.runOnQueue(Queues.MAIN)
    AsyncFunction("pause") { id: String ->
      Sessions.get(id).pausePlayback()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("stop") { id: String ->
      val session = Sessions.get(id)
      session.playbackFailed = false
      session.transitionPending = false
      session.resetFailures()
      session.clearAudioFocus()
      session.generation++
      session.autoAdvanceArmed = false
      session.pendingSeek = null
      session.player.stop()
    }.runOnQueue(Queues.MAIN)
    AsyncFunction("release") { id: String ->
      val session = Sessions.get(id)
      session.release()
      Sessions.items.remove(id)
      if (Sessions.pictureInPictureSessionId == id) Sessions.pictureInPictureSessionId = null
    }.runOnQueue(Queues.MAIN)

    View(PlayerView::class) {
      Prop("sessionId") { view: PlayerView, id: String? -> view.attach(id) }
      Prop("resizeMode") { view: PlayerView, mode: String? -> view.setResizeMode(mode) }
      Prop("disableResizeAnimation") { _: PlayerView, _: Boolean? -> Unit }
      OnViewDestroys { view: PlayerView -> view.detach() }
    }

    OnDestroy {
      android.os.Handler(android.os.Looper.getMainLooper()).post {
        MediaAnalysis.shutdown()
        Sessions.items.values.toList().forEach { it.release() }
        Sessions.items.clear()
        Sessions.pictureInPictureSessionId = null
      }
    }
  }
}
