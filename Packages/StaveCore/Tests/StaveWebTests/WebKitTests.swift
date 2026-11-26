import Testing

/// The parent of every suite that launches web content. `.serialized` on a parent covers its nested suites, so they run one test at a time
/// instead of side by side.
///
/// Why: each web content process WebKit launches costs the main thread a synchronous font query (`WebProcessPool.registerUserInstalledFonts`
/// asks the font server for every installed font over a blocking XPC call; seen in a `sample` of the macos-26 CI runner). With these suites
/// in parallel, dozens of launches landed at once and blocked the main thread for 10 to 30 s. Every wait in them (`waitUntil`, 20 s) and the
/// 8 s store-removal retry (`StoreCleanup`, "Data store is in use (by network process)") ran out while it was blocked, which looked like
/// failing page loads and a stalled store removal. Run one at a time, the "Page host" suite takes 7 to 11 s instead of 31 to 40 s.
@Suite("WebKit", .serialized)
enum WebKitTests {}
