// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import UIKit

/// The share sheet entry for slim-m: copies what was shared into the App Group,
/// then opens the app, which picks it up through `Runner/ShareIntakeChannel.swift`.
///
/// There is no UI to speak of. The person chooses where it goes inside the app,
/// the same picker Android's share sheet leads to.
final class ShareViewController: UIViewController {
  private var writer: ShareIntakeWriter?

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(spinner)
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    spinner.startAnimating()

    let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
    let providers = items.flatMap { $0.attachments ?? [] }
    guard let writer = ShareIntakeWriter() else {
      extensionContext?.cancelRequest(withError: ShareError.noGroupContainer)
      return
    }
    self.writer = writer
    writer.run(providers) { [weak self] written in
      DispatchQueue.main.async { self?.finish(written: written) }
    }
  }

  private func finish(written: Bool) {
    if written { openHostApp() }
    extensionContext?.completeRequest(returningItems: nil)
  }

  /// An extension has no `UIApplication.shared`, but the responder chain still ends in the host's
  /// application object, so its URL opener is called through the runtime rather than by name.
  private func openHostApp() {
    guard let url = URL(string: ShareIntakeRules.openURLString) else { return }
    typealias Opener = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, AnyObject?) -> Void
    let selector = NSSelectorFromString("openURL:options:completionHandler:")
    var responder: UIResponder? = self
    while let current = responder {
      if current is UIApplication, current.responds(to: selector),
        let method = class_getMethodImplementation(type(of: current), selector)
      {
        unsafeBitCast(method, to: Opener.self)(current, selector, url as NSURL, NSDictionary(), nil)
        return
      }
      responder = current.next
    }
  }

  private enum ShareError: Error {
    case noGroupContainer
  }
}
