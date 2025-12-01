class Edb < Formula
  desc "eXist-DB CLI toolkit – export/import, watch-sync, XAR build, backup & rollback"
  homepage "https://github.com/Docetis/edb"
  url "https://github.com/Docetis/edb/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "REPLACE_WITH_SHA256"
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
