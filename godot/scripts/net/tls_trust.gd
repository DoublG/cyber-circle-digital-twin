class_name TlsTrust
## Which certificates the game trusts for wss:// (the broker) and https:// (the
## control server). Default: the system's CAs. --ca=FILE: the installation's
## own CA (deploy/certs/ca.pem) - the server certificates are signed by it.

static var options: TLSOptions = null      # null = the defaults (system CAs)


static func load_ca(path: String) -> bool:
	var cert := X509Certificate.new()
	if cert.load(path) != OK:
		push_warning("--ca: cannot read a certificate from %s" % path)
		return false
	options = TLSOptions.client(cert)
	print("tls: trusting the CA in ", path)
	return true
