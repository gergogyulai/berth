# Template for Casks/berth.rb in gergogyulai/homebrew-tap.
# The release workflow fills in the version and checksum and pushes it to the tap.
cask "berth" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/gergogyulai/berth/releases/download/v#{version}/Berth-#{version}.zip"
  name "Berth"
  desc "Menu bar app that keeps SMB shares mounted at home, over Tailscale and after sleep"
  homepage "https://github.com/gergogyulai/berth"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "Berth.app"
  binary "#{appdir}/Berth.app/Contents/Helpers/berth"

  # The app isn't notarized (no paid Apple developer account). Without this, Gatekeeper blocks the first
  # launch and the user has to allow it in System Settings → Privacy & Security.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Berth.app"],
        writable_paths: ["Berth.app"],
        writable_base:  :appdir
  end

  uninstall quit:       "app.berth.Berth",
            login_item: "Berth"

  zap trash: [
    "~/Library/Application Support/Berth",
    "~/Library/Preferences/app.berth.Berth.plist",
  ]
end
