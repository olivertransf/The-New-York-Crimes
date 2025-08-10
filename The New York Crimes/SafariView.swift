//
//  SafariView.swift
//  The New York Crimes
//
//  Created by Assistant on 8/9/25.
//

#if os(iOS)
import SwiftUI
import SafariServices

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var entersReaderIfAvailable: Bool = true

    func makeUIViewController(context: Context) -> SFSafariViewController {
        if #available(iOS 11.0, *) {
            let config = SFSafariViewController.Configuration()
            config.entersReaderIfAvailable = entersReaderIfAvailable
            let vc = SFSafariViewController(url: url, configuration: config)
            return vc
        } else {
            let vc = SFSafariViewController(url: url, entersReaderIfAvailable: entersReaderIfAvailable)
            return vc
        }
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
        // No-op
    }
}
#endif


