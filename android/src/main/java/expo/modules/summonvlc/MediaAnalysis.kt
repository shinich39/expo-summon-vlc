package expo.modules.summonvlc

import android.content.Context
import android.graphics.Bitmap
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import expo.modules.kotlin.Promise
import org.videolan.libvlc.LibVLC
import org.videolan.libvlc.Media
import org.videolan.libvlc.interfaces.IMedia
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Confined to the main thread. One native analysis operation runs at a time.
internal object MediaAnalysis {
  private val main = Handler(Looper.getMainLooper())
  private val worker = Executors.newSingleThreadExecutor()
  private class Job(val id: String, val promise: Promise) {
    var done = false
    var media: Media? = null
    var vlc: LibVLC? = null
    var deadline: Runnable? = null
  }
  private var current: Job? = null

  private fun begin(id: String, timeout: Int, promise: Promise): Job? {
    if (id.isEmpty() || timeout !in 100..120000) {
      promise.reject("ERR_MEDIA_ARGUMENT", "A request ID and a timeout between 100 and 120000 ms are required", null)
      return null
    }
    if (current != null) {
      promise.reject("ERR_MEDIA_BUSY", "Another media analysis job is still running", null)
      return null
    }
    val job = Job(id, promise)
    current = job
    job.deadline = Runnable { cancelJob(job, "ERR_MEDIA_TIMEOUT", "Media analysis timed out") }
    main.postDelayed(job.deadline!!, timeout.toLong())
    return job
  }
  private fun cleanup(job: Job) {
    if (current !== job) return
    job.deadline?.let { main.removeCallbacks(it) }
    job.media?.setEventListener(null)
    job.media?.release()
    job.vlc?.release()
    job.media = null
    job.vlc = null
    current = null
  }
  private fun fail(job: Job, code: String, message: String, error: Throwable? = null) {
    if (current !== job || job.done) return
    job.done = true
    job.promise.reject(code, message, error)
    cleanup(job)
  }
  private fun cancelJob(job: Job, code: String, message: String) {
    if (current !== job || job.done) return
    job.done = true
    job.deadline?.let { main.removeCallbacks(it) }
    job.promise.reject(code, message, null)
    // The installed LibVLC Android API has no parseStop; the worker/native parser
    // retains the slot until its completion callback, preventing unbounded work.
  }
  fun cancel(id: String): Boolean {
    val job = current ?: return false
    if (job.id != id || job.done) return false
    cancelJob(job, "ERR_MEDIA_CANCELLED", "Media analysis was cancelled")
    return true
  }
  fun shutdown() { current?.let { cancelJob(it, "ERR_MEDIA_CANCELLED", "The module was destroyed") } }

  fun inspect(context: Context, id: String, uri: String, timeout: Int, promise: Promise) {
    val source = Uri.parse(uri)
    if (source.scheme?.lowercase() !in listOf("file", "http", "https")) {
      promise.reject("ERR_MEDIA_ARGUMENT", "Use a file, http, or https URI", null)
      return
    }
    val job = begin(id, timeout, promise) ?: return
    try {
      val vlc = LibVLC(context.applicationContext)
      job.vlc = vlc
      val media = Media(vlc, source)
      job.media = media
      media.setEventListener { event ->
        if (event.type == IMedia.Event.ParsedChanged) {
          val status = event.parsedStatus
          main.post {
            if (current !== job) return@post
            if (job.done) { cleanup(job); return@post }
            if (status != IMedia.ParsedStatus.Done) {
              fail(job, "ERR_MEDIA_PARSE", "Media parsing failed or timed out (status $status)")
              return@post
            }
            try {
              val tracks = (0 until media.trackCount).mapNotNull { index ->
                val track = media.getTrack(index) ?: return@mapNotNull null
                val type = when (track.type) {
                  IMedia.Track.Type.Video -> "video"
                  IMedia.Track.Type.Audio -> "audio"
                  IMedia.Track.Type.Text -> "text"
                  else -> "unknown"
                }
                val result = mutableMapOf<String, Any>("type" to type, "id" to track.id)
                track.codec?.let { result["codec"] = it }
                track.language?.let { result["language"] = it }
                if (track.bitrate > 0) result["bitrate"] = track.bitrate
                when (track) {
                  is IMedia.VideoTrack -> {
                    if (track.width > 0) result["width"] = track.width
                    if (track.height > 0) result["height"] = track.height
                    if (track.frameRateDen > 0) result["frameRate"] = track.frameRateNum.toDouble() / track.frameRateDen
                  }
                  is IMedia.AudioTrack -> {
                    if (track.channels > 0) result["channels"] = track.channels
                    if (track.rate > 0) result["sampleRate"] = track.rate
                  }
                }
                result
              }
              val result = mapOf("durationMillis" to media.duration.takeIf { it > 0 }, "title" to media.getMeta(IMedia.Meta.Title), "tracks" to tracks)
              job.done = true
              job.promise.resolve(result)
              cleanup(job)
            } catch (error: Exception) { fail(job, "ERR_MEDIA_PARSE", "Could not read media metadata", error) }
          }
        }
      }
      val flags = if (source.scheme.equals("file", true)) IMedia.Parse.ParseLocal else IMedia.Parse.ParseNetwork
      if (!media.parseAsync(flags, timeout)) fail(job, "ERR_MEDIA_PARSE", "Could not start media parsing")
    } catch (error: Exception) { fail(job, "ERR_MEDIA_PARSE", "Could not start media parsing", error) }
  }

  fun thumbnail(context: Context, id: String, uri: String, position: Double, timeout: Int, promise: Promise) {
    val source = Uri.parse(uri)
    if (!source.scheme.equals("file", true) || source.path.isNullOrEmpty() || !position.isFinite() || position < 0 || position > 1_000_000_000_000.0) {
      promise.reject("ERR_MEDIA_ARGUMENT", "Thumbnail requires a local file URI and a valid non-negative position", null)
      return
    }
    val job = begin(id, timeout, promise) ?: return
    val cache = context.applicationContext.cacheDir
    worker.execute {
      var file: File? = null
      var bitmap: Bitmap? = null
      var error: Exception? = null
      var width = 0
      var height = 0
      var retriever: MediaMetadataRetriever? = null
      try {
        val reader = MediaMetadataRetriever()
        retriever = reader
        reader.setDataSource(source.path!!)
        val timeUs = (position * 1000).toLong()
        val originalWidth = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: 0
        val originalHeight = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: 0
        val rotation = reader.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
        val displayWidth = if (rotation == 90 || rotation == 270) originalHeight else originalWidth
        val displayHeight = if (rotation == 90 || rotation == 270) originalWidth else originalHeight
        val scale = if (displayWidth > 0 && displayHeight > 0) min(1.0, 640.0 / max(displayWidth, displayHeight)) else 1.0
        bitmap = if (Build.VERSION.SDK_INT >= 27 && displayWidth > 0 && displayHeight > 0)
          reader.getScaledFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST, max(1, (displayWidth * scale).roundToInt()), max(1, (displayHeight * scale).roundToInt()))
        else reader.getFrameAtTime(timeUs, MediaMetadataRetriever.OPTION_CLOSEST)
        val frame = bitmap ?: throw IllegalStateException("Could not extract a frame")
        width = frame.width
        height = frame.height
        file = File(cache, "summon-vlc-${UUID.randomUUID()}.jpg")
        file.outputStream().use { if (!frame.compress(Bitmap.CompressFormat.JPEG, 85, it)) throw IllegalStateException("Could not encode thumbnail") }
      } catch (failure: Exception) { error = failure; file?.delete(); file = null }
      finally { bitmap?.recycle(); try { retriever?.release() } catch (_: Exception) {} }
      val resultFile = file
      val resultError = error
      val resultWidth = width
      val resultHeight = height
      main.post {
        if (current !== job || job.done) { resultFile?.delete(); if (current === job) cleanup(job); return@post }
        if (resultFile == null) { fail(job, "ERR_THUMBNAIL", resultError?.message ?: "Could not extract thumbnail", resultError); return@post }
        job.done = true
        job.promise.resolve(mapOf("uri" to Uri.fromFile(resultFile).toString(), "requestedPositionMillis" to position, "actualPositionMillis" to null, "width" to resultWidth, "height" to resultHeight))
        cleanup(job)
      }
    }
  }
}
