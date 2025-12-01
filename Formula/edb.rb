class Edb < Formula
  desc "eXist-DB CLI toolkit – export/import, watch-sync, XAR build, backup & rollback"
  homepage "https://github.com/Docetis/edb"
  url "https://github.com/Docetis/edb/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "79366fdcee8e2af349bdccd4c7c1aefd585e48c83b6d5b223b13d81ce185e0f5"
  license "MIT"

  depends_on "curl"
  depends_on "zip"

  def install
    bin.install "edb.sh" => "edb"
  end

  test do
    # Just print usage to ensure the binary runs
    system "#{bin}/edb"
  end
end
