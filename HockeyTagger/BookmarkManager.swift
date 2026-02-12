import Foundation

struct BookmarkManager {
    static func makeBookmark(for url: URL) -> Data? {
        do {
            // Create a security-scoped bookmark
            // We use .securityScopeAllowOnlyReadAccess for the source video
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
            return data
        } catch {
            print("Failed to create bookmark: \(error)")
            return nil
        }
    }
    
    static func resolveBookmark(_ data: Data) -> URL? {
        guard !data.isEmpty else {
            print("resolveBookmark: Data is empty")
            return nil
        }
        
        do {
            var isStale = false
            let url = try URL(resolvingBookmarkData: data,
                              options: .withSecurityScope,
                              relativeTo: nil,
                              bookmarkDataIsStale: &isStale)
            
            if isStale {
                print("Bookmark is stale")
                // In a real app, you might want to regenerate the bookmark here
            }
            
            return url
        } catch {
            print("Failed to resolve bookmark: \(error)")
            return nil
        }
    }
}