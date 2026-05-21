class Daka < Formula
  desc "macOS menu bar tracker for daily clock-in span"
  homepage "https://github.com/iBreaker/daka"
  url "https://github.com/iBreaker/daka/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "350b85318313102fa8ea389d5c23c31fb5c1ecca03e23e6e69d6f525a28c7e45"
  license :cannot_represent
  head "https://github.com/iBreaker/daka.git", branch: "main"

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
