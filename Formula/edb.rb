class Edb < Formula
  desc "eXist-DB CLI toolkit – export/import, watch-sync, XAR build, backup & rollback"
  homepage "https://github.com/Docetis/edb"
  url "https://github.com/Docetis/edb/archive/refs/tags/v0.0.1.tar.gz"
  sha256 "7961e67aae35363572d4a79bf653d194781ad2208153bd7eb012f88e70d84dc9"
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
