class Daka < Formula
  desc "macOS menu bar tracker for daily clock-in span"
  homepage "https://github.com/iBreaker/daka"
  url "https://github.com/iBreaker/daka/archive/refs/tags/v0.3.2.tar.gz"
  sha256 "d362bbabc312c53d54b5fe3f07dfcab91f4cf85e22397035790bb251eaf353d1"
  license :cannot_represent
  head "https://github.com/iBreaker/daka.git", branch: "main"

  def install
    system "scripts/build-app.sh", "--output", buildpath/"Daka.app"
    libexec.install "Daka.app"
    bin.write_exec_script opt_libexec/"Daka.app/Contents/MacOS/daka"
  end

  service do
    run [opt_libexec/"Daka.app/Contents/MacOS/daka"]
    keep_alive successful_exit: false
    process_type :interactive
    log_path var/"log/daka.log"
    error_log_path var/"log/daka.log"
  end

  test do
    assert_path_exists bin/"daka"
    assert_predicate bin/"daka", :executable?
    assert_path_exists libexec/"Daka.app/Contents/Info.plist"
    bundle_id = shell_output(
      "/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' #{libexec}/Daka.app/Contents/Info.plist",
    ).strip
    assert_equal "local.daka.menu",
      bundle_id
  end
end
