# pick version (match what you use in node-prep)
VERSION=v3.14.4

# detect arch
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

# download
curl -fsSL "https://get.helm.sh/helm-${VERSION}-linux-${ARCH}.tar.gz" -o helm.tar.gz

# extract
tar -xzf helm.tar.gz

# install
sudo mv linux-${ARCH}/helm /usr/local/bin/helm
sudo chmod +x /usr/local/bin/helm

# cleanup
rm -rf linux-${ARCH} helm.tar.gz

# verify
helm version --short
