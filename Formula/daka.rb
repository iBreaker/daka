class Daka < Formula
  desc "macOS menu bar tracker for daily clock-in span"
  homepage "https://github.com/iBreaker/daka"
  url "https://github.com/iBreaker/daka/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "2e10fb17c43deca902bbe3d89f976ab328bba980f0b1e2b07559cd2e37f6270e"
  license :cannot_represent
  head "https://github.com/iBreaker/daka.git", branch: "main"

  depends_on xcode: ["15.0", :build]

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/daka"
  end

  service do
    run [opt_bin/"daka"]
    keep_alive false
    log_path var/"log/daka.log"
    error_log_path var/"log/daka.log"
  end

  test do
    assert_path_exists bin/"daka"
    assert_predicate bin/"daka", :executable?
  end
end
