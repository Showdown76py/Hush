# homebrew cask for hush. publish to a tap (eg Showdown76py/homebrew-tap) after each release
# bump version and sha256 (printed at the end of ./scripts/release.sh)
#   brew install --cask showdown76py/tap/hush
cask "hush" do
  version "0.1.0"
  sha256 "REMPLACER_PAR_LE_SHA256_DU_DMG"

  url "https://github.com/Showdown76py/Hush/releases/download/v#{version}/Hush-#{version}.dmg"
  name "Hush"
  desc "Clean microphone that removes speaker sound for Discord, Zoom, Meet and OBS"
  homepage "https://github.com/Showdown76py/Hush"

  depends_on macos: ">= :sonoma"
  auto_updates true

  app "Hush.app"

  # virtual mic gets installed by the app on first launch (one password prompt)
  uninstall_preflight do
    system_command "/bin/rm", args: ["-rf", "/Library/Audio/Plug-Ins/HAL/Hush.driver"], sudo: true
    system_command "/usr/bin/killall", args: ["coreaudiod"], sudo: true, must_succeed: false
  end

  zap trash: [
    "~/Library/Preferences/io.github.showdown76py.Hush.plist",
    "~/Library/Caches/io.github.showdown76py.Hush",
  ]

  caveats <<~EOS
    Si Hush n'est pas notarisé (build sans compte Apple Developer), autorisez son ouverture dans
    Réglages Système › Confidentialité et sécurité › « Ouvrir quand même », ou lancez :
      xattr -dr com.apple.quarantine /Applications/Hush.app
  EOS
end
