/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import WebKit
import Telemetry
import OnePasswordExtension

protocol BrowserState {
    var url: URL? { get }
    var isLoading: Bool { get }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }
    var estimatedProgress: Double { get }
}

protocol WebController {
    var delegate: WebControllerDelegate? { get set }
    var canGoBack: Bool { get }
    var canGoForward: Bool { get }

    func load(_ request: URLRequest)
}

protocol WebControllerDelegate: class {
    func webControllerDidStartNavigation(_ controller: WebController)
    func webControllerDidFinishNavigation(_ controller: WebController)
    func webController(_ controller: WebController, didFailNavigationWithError error: Error)
    func webController(_ controller: WebController, didUpdateCanGoBack canGoBack: Bool)
    func webController(_ controller: WebController, didUpdateCanGoForward canGoForward: Bool)
    func webController(_ controller: WebController, didUpdateEstimatedProgress estimatedProgress: Double)
    func webController(_ controller: WebController, scrollViewWillBeginDragging scrollView: UIScrollView)
    func webController(_ controller: WebController, scrollViewDidEndDragging scrollView: UIScrollView)
    func webController(_ controller: WebController, scrollViewDidScroll scrollView: UIScrollView)
    func webController(_ controller: WebController, stateDidChange state: BrowserState)
    func webControllerShouldScrollToTop(_ controller: WebController) -> Bool
    func webController(_ controller: WebController, didUpdateTrackingProtectionStatus trackingStatus: TrackingProtectionStatus)
}

class WebViewController: UIViewController, WebController {
    weak var delegate: WebControllerDelegate?

    private var errorView = UIView()
    private var browserView = WKWebView()
    var onePasswordExtensionItem: NSExtensionItem!
    private var progressObserver: NSKeyValueObservation?
    private var trackingProtectionStatus = TrackingProtectionStatus.on(TPPageStats()) {
        didSet {
            delegate?.webController(self, didUpdateTrackingProtectionStatus: trackingProtectionStatus)
        }
    }

    fileprivate var trackingInformation = TPPageStats() {
        didSet {
            if case .on = trackingProtectionStatus {
                trackingProtectionStatus = .on(trackingInformation)
            }
        }
    }

    var printFormatter: UIPrintFormatter { return browserView.viewPrintFormatter() }
    var scrollView: UIScrollView { return browserView.scrollView }

    convenience init() {
        self.init(nibName: nil, bundle: nil)

        setupWebview()
        ContentBlockerHelper.shared.handler = reloadBlockers(_:)
    }

    func reset() {
        browserView.load(URLRequest(url: URL(string: "about:blank")!))
        browserView.navigationDelegate = nil
        browserView.removeFromSuperview()
        errorView.removeFromSuperview()
        trackingProtectionStatus = .on(TPPageStats())
        browserView = WKWebView()
        setupWebview()
    }

    // Browser proxy methods
    func load(_ request: URLRequest) {
        
        if AppInfo.hasConnectivity() {
            print("app has connectivity")
            errorView.removeFromSuperview()
            browserView.load(request)
            return
        }
        
        print("no connectivity while loading :(")
        
        reset()
        setupErrorView()
        
        let label = UILabel()
        let text = UIConstants.strings.errorNoInternet
        let attrString = NSMutableAttributedString(string: text)
        let style = NSMutableParagraphStyle()
        
        style.lineHeightMultiple = 1.5
        style.lineBreakMode = .byWordWrapping
        attrString.addAttribute(NSAttributedStringKey.paragraphStyle, value: style, range: NSRange(location: 0, length: text.count))
        label.attributedText = attrString
        label.numberOfLines = 0
        label.font = UIFont.systemFont(ofSize: 16, weight: .light)

        errorView.addSubview(label)

        let button = UIButton()
        button.setTitle(UIConstants.strings.errorTryAgainButton, for: .normal)
        button.backgroundColor = UIConstants.colors.settingsLink
        button.setTitleColor(UIColor.white, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        button.layer.cornerRadius = 12
        button.clipsToBounds = true
        
        button.addTarget(self, action: #selector(reload), for: .touchUpInside)
        
        errorView.addSubview(button)
        
        let errorStack = UIStackView(arrangedSubviews: [label, button])
        errorStack.axis = .vertical
        errorStack.spacing = 40
        
        errorView.addSubview(errorStack)
        guard let superview = view.superview else { return }
        
        button.snp.makeConstraints { make in
            make.height.equalTo(48)
        }

        errorStack.snp.makeConstraints { make in
            make.leading.equalTo(superview).offset(40)
            make.trailing.equalTo(superview).offset(-40)
            make.centerY.equalTo(view.snp.centerY)
        }
        
        view.layoutIfNeeded()
    }
    func goBack() { browserView.goBack() }
    func goForward() { browserView.goForward() }
    @objc func reload() { print("reloading"); browserView.reload() }
    
    @available(iOS 9, *)
    func requestDesktop() {
        guard let currentItem = browserView.backForwardList.currentItem else {
            return
        }
    
        browserView.customUserAgent = UserAgent.getDesktopUserAgent()
        
        if currentItem.url != currentItem.initialURL {
            // Reload the initial URL to avoid UA specific redirection
            browserView.load(URLRequest(url: currentItem.initialURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 60))
        } else {
            reload() // Reload the current URL. We cannot use loadRequest in this case because it seems to leverage caching.
        }
        
        // Unset the desktopUserAgent
        browserView.customUserAgent = UserAgent.browserUserAgent
    }
    
    func stop() { browserView.stopLoading() }

    private func setupWebview() {
        browserView.allowsBackForwardNavigationGestures = true
        browserView.allowsLinkPreview = false
        browserView.scrollView.clipsToBounds = false
        browserView.scrollView.delegate = self
        browserView.navigationDelegate = self
        browserView.uiDelegate = self

        progressObserver = browserView.observe(\WKWebView.estimatedProgress) { (webView, value) in
            self.delegate?.webController(self, didUpdateEstimatedProgress: webView.estimatedProgress)
        }

        setupBlockLists()
        setupUserScripts()

        view.addSubview(browserView)
        
        browserView.snp.makeConstraints { make in
            make.edges.equalTo(view.snp.edges)
        }
        
        setupErrorView()
    }
    
    private func setupErrorView() {
        view.addSubview(errorView)
        errorView.snp.makeConstraints{ make in
            make.edges.equalTo(browserView.snp.edges)
        }
    }

    @objc private func reloadBlockers(_ blockLists: [WKContentRuleList]) {
        DispatchQueue.main.async {
            self.browserView.configuration.userContentController.removeAllContentRuleLists()
            blockLists.forEach(self.browserView.configuration.userContentController.add)
        }
    }

    fileprivate func updateBackForwardState(webView: WKWebView) {
        delegate?.webController(self, didUpdateCanGoBack: canGoBack)
        delegate?.webController(self, didUpdateCanGoForward: canGoForward)
    }

    private func setupBlockLists() {
        ContentBlockerHelper.shared.getBlockLists { lists in
            self.reloadBlockers(lists)
        }
    }

    private func setupUserScripts() {
        browserView.configuration.userContentController.add(self, name: "focusTrackingProtection")
        let source = try! String(contentsOf: Bundle.main.url(forResource: "preload", withExtension: "js")!)
        let script = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        browserView.configuration.userContentController.addUserScript(script)

        browserView.configuration.userContentController.add(self, name: "focusTrackingProtectionPostLoad")
        let source2 = try! String(contentsOf: Bundle.main.url(forResource: "postload", withExtension: "js")!)
        let script2 = WKUserScript(source: source2, injectionTime: .atDocumentEnd, forMainFrameOnly: false)
        browserView.configuration.userContentController.addUserScript(script2)
    }

    func disableTrackingProtection() {
        guard case .on = trackingProtectionStatus else { return }

        browserView.configuration.userContentController.removeScriptMessageHandler(forName: "focusTrackingProtection")
        browserView.configuration.userContentController.removeScriptMessageHandler(forName: "focusTrackingProtectionPostLoad")
        browserView.configuration.userContentController.removeAllUserScripts()
        browserView.configuration.userContentController.removeAllContentRuleLists()
        trackingProtectionStatus = .off
    }

    func enableTrackingProtection() {
        guard case .off = trackingProtectionStatus else { return }

        setupBlockLists()
        setupUserScripts()
        trackingProtectionStatus = .on(TPPageStats())
    }
}

extension WebViewController: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        delegate?.webController(self, scrollViewDidScroll: scrollView)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        delegate?.webController(self, scrollViewWillBeginDragging: scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        delegate?.webController(self, scrollViewDidEndDragging: scrollView)
    }

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        return delegate?.webControllerShouldScrollToTop(self) ?? true
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        delegate?.webControllerDidStartNavigation(self)
        if case .on = trackingProtectionStatus { trackingInformation = TPPageStats() }

        updateBackForwardState(webView: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.webControllerDidFinishNavigation(self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        delegate?.webController(self, didFailNavigationWithError: error)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let present: (UIViewController) -> Void = { self.present($0, animated: true, completion: nil) }

        // prevent Focus from opening universal links
        // https://stackoverflow.com/questions/38450586/prevent-universal-links-from-opening-in-wkwebview-uiwebview
        let allowDecision = WKNavigationActionPolicy(rawValue: WKNavigationActionPolicy.allow.rawValue + 2) ?? .allow

        let decision: WKNavigationActionPolicy = RequestHandler().handle(request: navigationAction.request, alertCallback: present) ? allowDecision : .cancel
        if navigationAction.navigationType == .linkActivated && browserView.url != navigationAction.request.url {
            Telemetry.default.recordEvent(category: TelemetryEventCategory.action, method: TelemetryEventMethod.click, object: TelemetryEventObject.websiteLink)
        }
        decisionHandler(decision)
    }
}

extension WebViewController: BrowserState {
    var canGoBack: Bool { return browserView.canGoBack }
    var canGoForward: Bool { return browserView.canGoForward }
    var estimatedProgress: Double { return browserView.estimatedProgress }
    var isLoading: Bool { return browserView.isLoading }
    var url: URL? { return browserView.url }
}

extension WebViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            browserView.load(navigationAction.request)
        }

        return nil
    }
}


extension WebViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: String],
            let urlString = body["url"],
            var components = URLComponents(string: urlString) else {
                return
        }

        components.scheme = "http"
        guard let url = components.url else { return }

        let enabled = Utils.getEnabledLists().compactMap { BlocklistName(rawValue: $0) }
        TPStatsBlocklistChecker.shared.isBlocked(url: url, enabledLists: enabled).uponQueue(.main) { listItem in
            if let listItem = listItem {
                self.trackingInformation = self.trackingInformation.create(byAddingListItem: listItem)
            }
        }
    }
}

extension WebViewController {
    func createPasswordManagerExtensionItem() {
        OnePasswordExtension.shared().createExtensionItem(forWebView: browserView, completion: {(extensionItem, error) -> Void in
            if extensionItem == nil {
                return
            }
            // Set the 1Password extension item property
            self.onePasswordExtensionItem = extensionItem
        })
    }
    
    func fillPasswords(returnedItems: [AnyObject]) {
        OnePasswordExtension.shared().fillReturnedItems(returnedItems, intoWebView: browserView, completion: { (success, returnedItemsError) -> Void in
            if !success {
                return
            }
        })
    }
}
