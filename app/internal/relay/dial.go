package relay

import (
	"errors"
	"fmt"
	"net"
	"net/netip"
	"syscall"
	"time"
)

// ErrBlockedAddress is returned when a subscriber URL resolves to a non-public address.
var ErrBlockedAddress = errors.New("subscriber resolves to a non-public address")

// cgnat is shared address space (RFC 6598), which IsPrivate does not cover.
var cgnat = netip.MustParsePrefix("100.64.0.0/10")

// newDialer checks the resolved address in Control, which runs after DNS and before
// connect, so a hostname that re-resolves to an internal IP is still refused.
func newDialer(allowPrivate bool) *net.Dialer {
	d := &net.Dialer{Timeout: 5 * time.Second, KeepAlive: 30 * time.Second}
	if allowPrivate {
		return d
	}
	d.Control = func(_, address string, _ syscall.RawConn) error {
		host, _, err := net.SplitHostPort(address)
		if err != nil {
			return err
		}
		ip, err := netip.ParseAddr(host)
		if err != nil {
			return err
		}
		if !publicAddr(ip) {
			return fmt.Errorf("%w: %s", ErrBlockedAddress, ip)
		}
		return nil
	}
	return d
}

// publicAddr rejects loopback, RFC 1918, link-local (169.254.0.0/16, which holds the ECS
// credentials endpoint), CGNAT, multicast and unspecified addresses, in IPv4 and IPv6.
func publicAddr(ip netip.Addr) bool {
	ip = ip.Unmap()
	return ip.IsGlobalUnicast() && !ip.IsPrivate() && !cgnat.Contains(ip)
}
