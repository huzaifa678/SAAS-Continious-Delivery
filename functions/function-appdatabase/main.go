// Command function-appdatabase is a Crossplane composition function that
// composes a Postgres Role + Database + Grant (and any requested extensions)
// for the platform.saas.example XAppDatabase API. It is the code form of what
// used to be the function-patch-and-transform YAML in
// platform/compositions/appdatabase-postgres.yaml.
package main

import (
	"github.com/alecthomas/kong"

	function "github.com/crossplane/function-sdk-go"
)

// CLI of this Function.
type CLI struct {
	Debug bool `short:"d" help:"Emit debug logs in addition to info logs."`

	Network     string `help:"Network on which to listen for gRPC connections." default:"tcp"`
	Address     string `help:"Address at which to listen for gRPC connections." default:":9443"`
	TLSCertsDir string `help:"Directory containing server certs (tls.key, tls.crt) and the CA used to verify clients (ca.crt)." env:"TLS_SERVER_CERTS_DIR"`
	Insecure    bool   `help:"Run without mTLS credentials. If you supply this flag --tls-certs-dir will be ignored."`
}

// Run this Function.
func (c *CLI) Run() error {
	log, err := function.NewLogger(c.Debug)
	if err != nil {
		return err
	}

	return function.Serve(&Function{log: log},
		function.Listen(c.Network, c.Address),
		function.MTLSCertificates(c.TLSCertsDir),
		function.Insecure(c.Insecure))
}

func main() {
	ctx := kong.Parse(&CLI{},
		kong.Description("A Crossplane composition function for platform.saas.example XAppDatabase."),
		kong.UsageOnError())
	ctx.FatalIfErrorf(ctx.Run())
}
