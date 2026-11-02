import MobileVLCKit
import UIKit

/// Isolated manual experiment; this is not the module's player implementation.
final class PlaybackGateViewController: UIViewController {
  private let player = VLCMediaPlayer()
  private let videoView = UIView()
  private let sources: [URL]
  private var currentIndex = 0

  init(first: URL, second: URL) {
    precondition(first.isFileURL && second.isFileURL, "Use local video files")
    sources = [first, second]
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("Create this controller with two local file URLs")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    videoView.backgroundColor = .black
    videoView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(videoView)

    let controls = UIStackView(arrangedSubviews: [
      makeButton("Play", action: #selector(play)),
      makeButton("Pause", action: #selector(pause)),
      makeButton("Switch file", action: #selector(switchFile))
    ])
    controls.axis = .horizontal
    controls.distribution = .fillEqually
    controls.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controls)

    NSLayoutConstraint.activate([
      videoView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      videoView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      videoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      videoView.heightAnchor.constraint(equalTo: videoView.widthAnchor, multiplier: 9.0 / 16.0),
      controls.topAnchor.constraint(equalTo: videoView.bottomAnchor, constant: 16),
      controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
      controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
    ])

    player.drawable = videoView
    player.media = VLCMedia(url: sources[currentIndex])
  }

  private func makeButton(_ title: String, action: Selector) -> UIButton {
    let button = UIButton(type: .system)
    button.setTitle(title, for: .normal)
    button.addTarget(self, action: action, for: .touchUpInside)
    return button
  }

  @objc private func play() {
    player.play()
  }

  @objc private func pause() {
    player.pause()
  }

  @objc private func switchFile() {
    player.stop()
    currentIndex = (currentIndex + 1) % sources.count
    player.media = VLCMedia(url: sources[currentIndex])
    player.play()
  }

  deinit {
    player.stop()
    player.drawable = nil
  }
}
