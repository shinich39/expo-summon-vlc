import UIKit
import UniformTypeIdentifiers

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = UINavigationController(rootViewController: FileSelectionViewController())
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}

private final class FileSelectionViewController: UIViewController, UIDocumentPickerDelegate {
  private var sources: [URL] = []
  private let status = UILabel()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Playback gate"
    view.backgroundColor = .systemBackground

    status.text = "Select the first local video file."
    status.numberOfLines = 0
    status.textAlignment = .center
    let select = UIButton(type: .system)
    select.setTitle("Select video", for: .normal)
    select.addTarget(self, action: #selector(selectVideo), for: .touchUpInside)
    let stack = UIStackView(arrangedSubviews: [status, select])
    stack.axis = .vertical
    stack.spacing = 16
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
      stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24)
    ])
  }

  @objc private func selectVideo() {
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
    picker.delegate = self
    picker.allowsMultipleSelection = false
    present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let url = urls.first else { return }
    sources.append(url)
    if sources.count == 1 {
      status.text = "Select the second local video file."
      return
    }

    let playback = PlaybackGateViewController(first: sources[0], second: sources[1])
    sources.removeAll()
    status.text = "Select the first local video file."
    navigationController?.pushViewController(playback, animated: true)
  }
}
