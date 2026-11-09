import SwiftUI

@main
struct LyricLiveApp: App {
    @StateObject private var spotify = SpotifyClient()

    var body: some Scene {
        WindowGroup {
            ContentView(spotify: spotify)
                .preferredColorScheme(.dark)
                .onOpenURL { url in spotify.handleURL(url) }
        }
    }
}

