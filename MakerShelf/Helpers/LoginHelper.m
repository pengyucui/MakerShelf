#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

@interface LoginApp : NSObject <NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate>
@property (nonatomic) NSWindow *window;
@property (nonatomic) WKWebView *webView;
@property (nonatomic) NSTextField *urlField;
@property (nonatomic) NSTextField *statusField;
@property (nonatomic) NSButton *captureButton;
@property (nonatomic) NSURL *startURL;
@property (nonatomic) NSString *outPath;
@property (nonatomic) NSString *windowTitle;
@property (nonatomic) NSMutableArray<NSWindow *> *popups;
@property (nonatomic) BOOL busy;
@end

@implementation LoginApp

static NSString *HarvestScript(void) {
    return @"const tokens = [];\n"
    "const storage = {};\n"
    "function walk(value) {\n"
    "  if (typeof value === 'string') {\n"
    "    const matches = value.match(/eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+/g);\n"
    "    if (matches) tokens.push(...matches);\n"
    "    try { walk(JSON.parse(value)); } catch (e) {}\n"
    "    return;\n"
    "  }\n"
    "  if (value && typeof value === 'object') {\n"
    "    for (const key of Object.keys(value)) walk(value[key]);\n"
    "  }\n"
    "}\n"
    "try {\n"
    "  for (let i = 0; i < localStorage.length; i++) {\n"
    "    const key = localStorage.key(i);\n"
    "    storage[key] = localStorage.getItem(key);\n"
    "  }\n"
    "} catch (e) {}\n"
    "try {\n"
    "  for (let i = 0; i < sessionStorage.length; i++) {\n"
    "    const key = sessionStorage.key(i);\n"
    "    storage['session:' + key] = sessionStorage.getItem(key);\n"
    "  }\n"
    "} catch (e) {}\n"
    "walk(storage);\n"
    "walk(document.cookie);\n"
    "const cookieToken = (document.cookie.match(/(?:^|; )token=([^;]*)/) || [])[1];\n"
    "if (cookieToken) tokens.push(decodeURIComponent(cookieToken));\n"
    "let buildId = null;\n"
    "const next = document.getElementById('__NEXT_DATA__');\n"
    "if (next && next.textContent) {\n"
    "  walk(next.textContent);\n"
    "  try { buildId = JSON.parse(next.textContent).buildId; } catch (e) {}\n"
    "}\n"
    "const webHeaders = {\n"
    "  'Accept': 'application/json, text/plain, */*',\n"
    "  'x-bbl-app-source': 'makerworld',\n"
    "  'x-bbl-client-name': 'MakerWorld',\n"
    "  'x-bbl-client-type': 'web',\n"
    "  'x-bbl-client-version': '00.00.00.01'\n"
    "};\n"
    "let profile = null;\n"
    "const handle = (location.pathname.match(/@([^/]+)/) || [])[1] || null;\n"
    "const urls = [\n"
    "  '/api/v1/design-user-service/my/preference',\n"
    "  '/api/v1/design-user-service/my/profile?immediacy=true',\n"
    "  '/api/v1/user-service/my/profile'\n"
    "];\n"
    "if (buildId && handle) {\n"
    "  urls.push('/_next/data/' + buildId + '/zh/@' + handle + '.json?handle=%40' + handle);\n"
    "}\n"
    "for (const url of urls) {\n"
    "  try {\n"
    "    const headers = Object.assign({}, webHeaders);\n"
    "    if (url.indexOf('_next/data') !== -1) headers['x-nextjs-data'] = '1';\n"
    "    const response = await fetch(url, { credentials: 'include', headers: headers });\n"
    "    const text = await response.text();\n"
    "    if (response.ok && text.trim().startsWith('{')) {\n"
    "      const json = JSON.parse(text);\n"
    "      profile = json.pageProps || json;\n"
    "      walk(text);\n"
    "      break;\n"
    "    }\n"
    "  } catch (e) {}\n"
    "}\n"
    "return JSON.stringify({ tokens, storage, profile, handle, href: location.href, userAgent: navigator.userAgent });";
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.popups = [NSMutableArray array];
    [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self attachWebView];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (void)buildWindow {
    NSRect rect = NSMakeRect(0, 0, 920, 720);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:rect
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:YES];
    window.title = self.windowTitle.length ? self.windowTitle : @"连接 MakerWorld";
    window.releasedWhenClosed = NO;
    window.delegate = self;
    window.minSize = NSMakeSize(720, 560);
    NSView *root = [[NSView alloc] initWithFrame:rect];
    window.contentView = root;

    NSTextField *title = [NSTextField labelWithString:window.title];
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *url = [NSTextField labelWithString:self.startURL.absoluteString ?: @""];
    url.font = [NSFont systemFontOfSize:11];
    url.textColor = [NSColor secondaryLabelColor];
    url.lineBreakMode = NSLineBreakByTruncatingMiddle;
    url.translatesAutoresizingMaskIntoConstraints = NO;
    self.urlField = url;

    NSTextField *hint = [NSTextField wrappingLabelWithString:@"这是独立登录进程。遇到真人验证请等待；登录后停在个人主页，再点「我已完成登录」。"];
    hint.font = [NSFont systemFontOfSize:12];
    hint.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *host = [[NSView alloc] initWithFrame:NSZeroRect];
    host.wantsLayer = YES;
    host.layer.backgroundColor = NSColor.whiteColor.CGColor;
    host.identifier = @"host";
    host.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *status = [NSTextField wrappingLabelWithString:@"正在打开 MakerWorld…"];
    status.font = [NSFont systemFontOfSize:12];
    status.textColor = [NSColor secondaryLabelColor];
    status.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusField = status;

    NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelTapped)];
    cancel.keyEquivalent = @"\e";
    NSButton *reset = [NSButton buttonWithTitle:@"重新验证" target:self action:@selector(resetTapped)];
    NSButton *capture = [NSButton buttonWithTitle:@"我已完成登录" target:self action:@selector(captureTapped)];
    self.captureButton = capture;

    NSStackView *buttons = [NSStackView stackViewWithViews:@[cancel, reset, [NSView new], capture]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, url, hint, host, status, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-22],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor constant:18],
        [stack.bottomAnchor constraintEqualToAnchor:root.bottomAnchor constant:-18],
        [host.heightAnchor constraintGreaterThanOrEqualToConstant:480],
        [host.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [url.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [hint.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [status.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
    ]];
    [window center];
    self.window = window;
}

- (NSView *)hostView {
    for (NSView *view in self.window.contentView.subviews) {
        if (![view isKindOfClass:[NSStackView class]]) continue;
        for (NSView *child in ((NSStackView *)view).arrangedSubviews) {
            if ([child.identifier isEqualToString:@"host"]) return child;
        }
    }
    return nil;
}

- (void)attachWebView {
    NSView *host = [self hostView];
    if (!host || self.webView) return;
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
    config.defaultWebpagePreferences.allowsContentJavaScript = YES;
    WKWebView *web = [[WKWebView alloc] initWithFrame:host.bounds configuration:config];
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    web.navigationDelegate = self;
    web.UIDelegate = self;
    web.allowsBackForwardNavigationGestures = YES;
    [host addSubview:web];
    self.webView = web;
    if (self.startURL) [web loadRequest:[NSURLRequest requestWithURL:self.startURL]];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSString *url = webView.URL.absoluteString ?: @"";
    self.urlField.stringValue = url;
    if ([url containsString:@"cdn-cgi"] || [url containsString:@"challenge"]) {
        self.statusField.stringValue = @"正在通过安全验证，请稍候。";
    } else if (url.length) {
        self.statusField.stringValue = @"在页面中登录。完成后点「我已完成登录」。";
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    if ([@[@"http", @"https", @"about", @"blob", @"data"] containsObject:scheme]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
    decisionHandler(WKNavigationActionPolicyCancel);
}

- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures {
    CGFloat width = windowFeatures.width ? windowFeatures.width.doubleValue : 520;
    CGFloat height = windowFeatures.height ? windowFeatures.height.doubleValue : 720;
    WKWebView *popup = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, MAX(width, 420), MAX(height, 520)) configuration:configuration];
    popup.navigationDelegate = self;
    popup.UIDelegate = self;
    NSWindow *win = [[NSWindow alloc] initWithContentRect:popup.frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    win.title = @"登录";
    win.contentView = popup;
    win.releasedWhenClosed = NO;
    [win center];
    [win makeKeyAndOrderFront:nil];
    [self.popups addObject:win];
    self.statusField.stringValue = @"已打开登录窗口，完成后回到此页点「我已完成登录」。";
    return popup;
}

- (void)webViewDidClose:(WKWebView *)webView {
    NSMutableArray *keep = [NSMutableArray array];
    for (NSWindow *win in self.popups) {
        if (win.contentView == webView) [win close];
        else [keep addObject:win];
    }
    self.popups = keep;
}

- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    [alert addButtonWithTitle:@"确定"];
    [alert runModal];
    completionHandler();
}

- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = message;
    [alert addButtonWithTitle:@"确定"];
    [alert addButtonWithTitle:@"取消"];
    completionHandler([alert runModal] == NSAlertFirstButtonReturn);
}

- (void)cancelTapped {
    [self writePayload:@{@"cancelled": @YES} exitCode:0];
}

- (void)resetTapped {
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        dispatch_group_t group = dispatch_group_create();
        for (NSHTTPCookie *cookie in cookies) {
            NSString *name = cookie.name.lowercaseString;
            NSString *domain = cookie.domain.lowercaseString;
            if ([name containsString:@"cf"] || [domain containsString:@"cloudflare"]) {
                dispatch_group_enter(group);
                [store deleteCookie:cookie completionHandler:^{ dispatch_group_leave(group); }];
            }
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            NSURLRequest *req = [NSURLRequest requestWithURL:self.startURL cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval:30];
            [self.webView loadRequest:req];
        });
    }];
}

- (void)captureTapped {
    if (self.busy || !self.webView) return;
    self.busy = YES;
    self.captureButton.enabled = NO;
    self.statusField.stringValue = @"正在读取网页登录状态…";
    WKHTTPCookieStore *store = self.webView.configuration.websiteDataStore.httpCookieStore;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        [self.webView callAsyncJavaScript:HarvestScript() arguments:@{} inFrame:nil inContentWorld:WKContentWorld.pageWorld
                        completionHandler:^(id result, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableArray *list = [NSMutableArray array];
            for (NSHTTPCookie *cookie in cookies) {
                [list addObject:@{
                    @"name": cookie.name ?: @"",
                    @"value": cookie.value ?: @"",
                    @"domain": cookie.domain ?: @"",
                    @"path": cookie.path ?: @"/"
                }];
            }
            NSMutableDictionary *payload = [@{
                @"cancelled": @NO,
                @"url": self.webView.URL.absoluteString ?: @"",
                @"cookies": list
            } mutableCopy];
            NSDictionary *harvest = nil;
            if ([result isKindOfClass:[NSString class]]) {
                NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
                harvest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            } else if ([result isKindOfClass:[NSDictionary class]]) {
                harvest = result;
            }
            if ([harvest isKindOfClass:[NSDictionary class]]) {
                if (harvest[@"tokens"]) payload[@"tokens"] = harvest[@"tokens"];
                if (harvest[@"storage"]) payload[@"storage"] = harvest[@"storage"];
                if (harvest[@"profile"]) payload[@"profile"] = harvest[@"profile"];
                if (harvest[@"handle"]) payload[@"handle"] = harvest[@"handle"];
                if (harvest[@"userAgent"]) payload[@"userAgent"] = harvest[@"userAgent"];
                if (harvest[@"href"]) payload[@"url"] = harvest[@"href"];
            }
            [self writePayload:payload exitCode:0];
            });
        }];
    }];
}

- (void)writePayload:(NSDictionary *)payload exitCode:(int)code {
    if (self.outPath.length) {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:NSJSONWritingPrettyPrinted error:&error];
        if (data) [data writeToFile:self.outPath atomically:YES];
    }
    for (NSWindow *win in self.popups) [win close];
    [self.window close];
    [NSApp terminate:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    if (notification.object == self.window && !self.busy) {
        if (self.outPath.length && ![[NSFileManager defaultManager] fileExistsAtPath:self.outPath]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"cancelled": @YES} options:0 error:nil];
            [data writeToFile:self.outPath atomically:YES];
        }
    }
}

@end

static NSString *ArgValue(int argc, const char **argv, NSString *flag) {
    NSString *key = flag;
    for (int i = 1; i < argc - 1; i++) {
        if ([key isEqualToString:@(argv[i])]) return @(argv[i + 1]);
    }
    return nil;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        LoginApp *app = [[LoginApp alloc] init];
        NSString *url = ArgValue(argc, argv, @"--url");
        app.startURL = url.length ? [NSURL URLWithString:url] : [NSURL URLWithString:@"https://makerworld.com/zh"];
        app.outPath = ArgValue(argc, argv, @"--out");
        app.windowTitle = ArgValue(argc, argv, @"--title") ?: @"连接 MakerWorld";
        NSApp.delegate = app;
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        [NSApp run];
    }
    return 0;
}
