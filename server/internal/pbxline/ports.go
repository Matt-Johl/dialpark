package pbxline

import (
	"fmt"
	"strconv"
	"strings"
)

// PortRange is the PBX leg in lines mode with a socket per line: one UDP
// listener on every port from First to Last, each registered line holding
// one of them for as long as it exists. An exchange binds a third-party
// SIP device to the address and port it registers from, one device per
// address (CUCM, 2026-10-29: the second line to register from the shared
// socket took the first one's place and the first was refused from then
// on), so lines that share a socket can never all be registered at once.
// The zero value is the single shared socket, which is what trunk mode and
// a lines deployment without a range still get.
type PortRange struct {
	First, Last int
}

// maxLinePorts bounds a range: a socket per port is bound at start-up
// whether or not a line ever takes it.
const maxLinePorts = 256

// ParsePortRange reads "first-last". Both ends are inclusive.
func ParsePortRange(s string) (PortRange, error) {
	s = strings.TrimSpace(s)
	if s == "" {
		return PortRange{}, nil
	}
	a, b, ok := strings.Cut(s, "-")
	if !ok {
		return PortRange{}, fmt.Errorf("want first-last, got %q", s)
	}
	first, err1 := strconv.Atoi(strings.TrimSpace(a))
	last, err2 := strconv.Atoi(strings.TrimSpace(b))
	if err1 != nil || err2 != nil || first <= 0 || last > 65535 {
		return PortRange{}, fmt.Errorf("want two ports 1-65535 as first-last, got %q", s)
	}
	if last < first {
		return PortRange{}, fmt.Errorf("last port before first in %q", s)
	}
	if last-first+1 > maxLinePorts {
		return PortRange{}, fmt.Errorf("%q is more than %d ports", s, maxLinePorts)
	}
	return PortRange{First: first, Last: last}, nil
}

// Len is the number of ports, 0 for the zero value.
func (r PortRange) Len() int {
	if r.First == 0 {
		return 0
	}
	return r.Last - r.First + 1
}

// Contains reports whether p is one of the range's ports.
func (r PortRange) Contains(p int) bool { return r.Len() > 0 && p >= r.First && p <= r.Last }

func (r PortRange) String() string {
	if r.Len() == 0 {
		return ""
	}
	return strconv.Itoa(r.First) + "-" + strconv.Itoa(r.Last)
}
